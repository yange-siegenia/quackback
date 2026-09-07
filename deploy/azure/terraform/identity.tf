# ============================================================================
# Identity, registry and secrets
#
# One user-assigned identity is used by all three workloads (web, worker,
# migration job). It is what pulls from the registry and what dereferences Key
# Vault secret references, so no credential is ever written into a container
# app's configuration.
# ============================================================================

resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.name_prefix}-identity"
  resource_group_name = local.resource_group_name
  location            = local.location
  tags                = var.tags
}

resource "azurerm_container_registry" "main" {
  name                = local.registry_name
  resource_group_name = local.resource_group_name
  location            = local.location
  sku                 = "Standard"
  # Identity-based pulls only; there is no admin user to leak.
  admin_enabled = false
  tags          = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  count = var.manage_role_assignments ? 1 : 0

  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  resource_group_name = local.resource_group_name
  location            = local.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC rather than access policies: the role assignments below are then the
  # single, auditable statement of who can read these secrets.
  rbac_authorization_enabled = true

  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  tags = var.tags
}

# The identity the containers run as may read secret values.
resource "azurerm_role_assignment" "kv_app_read" {
  count = var.manage_role_assignments ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Whoever runs `terraform apply` must be able to write them.
resource "azurerm_role_assignment" "kv_deployer_write" {
  count = var.manage_role_assignments ? 1 : 0

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Secret values
# ---------------------------------------------------------------------------

resource "random_password" "secret_key" {
  length  = 48
  special = false
}

locals {
  # A generated key is the safe default; an explicitly supplied one is honoured
  # so an existing deployment's sessions and encrypted columns survive a move.
  secret_key = var.secret_key != "" ? var.secret_key : random_password.secret_key.result

  # Every secret the workloads need, in one map so the vault entries and the
  # container-app secret blocks cannot drift apart.
  secret_values = {
    "database-url"        = local.database_url
    "secret-key"          = local.secret_key
    "storage-account-key" = azurerm_storage_account.main.primary_access_key
    "smtp-password"       = var.email_smtp_password
    "openai-api-key"      = var.openai_api_key
  }

  # Which secrets exist, as plain names.
  #
  # Kept separate from the values above because Terraform refuses a sensitive
  # value as a `for_each` key — it would end up in resource addresses and plan
  # output. `nonsensitive` is applied to the *predicate*, not to the secret:
  # whether SMTP is configured is not itself a secret, only the password is.
  #
  # The three unconditional entries are required for the app to boot at all;
  # the optional two are absent rather than blank when their feature is off.
  enabled_secrets = toset(concat(
    ["database-url", "secret-key", "storage-account-key"],
    nonsensitive(var.email_smtp_password != "") ? ["smtp-password"] : [],
    nonsensitive(var.openai_api_key != "") ? ["openai-api-key"] : [],
  ))
}

resource "azurerm_key_vault_secret" "app" {
  for_each = local.enabled_secrets

  name         = each.value
  value        = local.secret_values[each.value]
  key_vault_id = azurerm_key_vault.main.id

  # Role assignments are eventually consistent; without this the first apply
  # races the data-plane permission it just granted itself.
  depends_on = [azurerm_role_assignment.kv_deployer_write]
}
