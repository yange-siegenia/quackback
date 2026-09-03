terraform {
  required_version = ">= 1.6"

  # Remote state, configured at init time so the same configuration can be
  # pointed at more than one environment:
  #
  #   terraform init \
  #     -backend-config="resource_group_name=..." \
  #     -backend-config="storage_account_name=..." \
  #     -backend-config="container_name=tfstate" \
  #     -backend-config="key=quackback.tfstate"
  #
  # The state holds the database password and the session signing key, so the
  # backing container must not be public. Use `-backend=false` for a local
  # validate-only run.
  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # The provider otherwise tries to register ~30 resource providers on every
  # run — Databricks, HDInsight, ServiceFabric and other things this deployment
  # never creates. Registration is a subscription-scope write, so on any
  # subscription where you hold rights only on a resource group the provider
  # fails before it plans anything, listing errors for services that are not
  # part of this stack at all.
  #
  # The providers this stack does need are listed in deploy/azure/README.md and
  # must be registered once, by someone with subscription rights.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # A destroyed vault stays recoverable for the soft-delete window, so a
      # destroy-then-apply under the same name would otherwise fail against a
      # name the deleted vault still holds.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}
