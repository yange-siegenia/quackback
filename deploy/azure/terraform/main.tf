# ============================================================================
# Foundation: resource group, naming, logs, network
# ============================================================================

data "azurerm_client_config" "current" {}

# A short suffix keeps the globally-unique names (registry, storage account,
# key vault) from colliding across environments without forcing the operator to
# invent one per deployment.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Registry and storage account names admit no separators and cap at 24 chars.
  registry_name        = "${var.name_prefix}acr${local.suffix}"
  storage_account_name = "${var.name_prefix}st${local.suffix}"
  key_vault_name       = "${var.name_prefix}-kv-${local.suffix}"

  database_name  = "quackback"
  blob_container = "quackback"

  # Read through the resource or the data source depending on which one exists,
  # rather than through var.resource_group_name directly. Both branches are a
  # reference, so every resource below inherits an implicit dependency on the
  # group and Terraform cannot race ahead of it.
  resource_group_name     = var.create_resource_group ? azurerm_resource_group.main[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_location = var.create_resource_group ? azurerm_resource_group.main[0].location : data.azurerm_resource_group.existing[0].location

  # The public origin. A custom domain wins; otherwise the app is reached on the
  # environment's default domain, which is known before the app itself exists.
  base_url = var.custom_domain != "" ? "https://${var.custom_domain}" : "https://${var.name_prefix}-web.${azurerm_container_app_environment.main.default_domain}"
}

locals {
  # Only ever the requested name: this is what the group is created as, and what
  # the data source looks up. It must not read back from either, or adopting an
  # existing group becomes a cycle.
  resource_group_name_requested = var.resource_group_name != "" ? var.resource_group_name : "${var.name_prefix}-rg"
}

resource "azurerm_resource_group" "main" {
  count = var.create_resource_group ? 1 : 0

  name     = local.resource_group_name_requested
  location = var.location
  tags     = var.tags
}

# Adopting a group someone else owns. Its location wins over var.location for
# everything placed inside it — Azure will not accept a child resource in a
# different region than a parent that pins one.
data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1

  name = local.resource_group_name_requested
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "${var.name_prefix}-logs"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Network
#
# Both datastores are private. That is what makes the migration step a
# Container Apps Job rather than a step in the GitHub Actions runner: nothing
# outside this VNet can reach Postgres, including CI.
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "main" {
  name                = "${var.name_prefix}-vnet"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.apps_subnet_prefix]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }

  # Reaching the storage account over the Microsoft backbone rather than the
  # public internet. Paired with the account's network rules below.
  service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.postgres_subnet_prefix]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}-${local.suffix}.private.postgres.database.azure.com"
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.name_prefix}-postgres-link"
  resource_group_name   = local.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}
