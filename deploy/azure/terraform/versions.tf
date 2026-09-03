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
