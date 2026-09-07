# ============================================================================
# Object storage — Azure Blob
#
# Consumed through the `azure_blob` storage driver added in
# apps/web/src/lib/server/storage/azure-blob.ts. Azure Blob has no S3 API, so
# pointing S3_ENDPOINT at it does not work; STORAGE_DRIVER=azure_blob selects
# the real driver, and the S3_* variables are reused as role names:
#
#   S3_BUCKET            -> blob container
#   S3_ACCESS_KEY_ID     -> storage account name
#   S3_SECRET_ACCESS_KEY -> storage account key
#   S3_ENDPOINT          -> blob endpoint
#
# The container is PRIVATE. Uploads are served through the app's /api/storage
# route, which mints a short-lived SAS and redirects — the same shape the
# bundled compose file uses with MinIO (S3_PROXY=true).
# ============================================================================

resource "azurerm_storage_account" "main" {
  name                = local.storage_account_name
  resource_group_name = local.resource_group_name
  location            = local.location

  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  # The driver signs SAS tokens with the account key, so shared-key auth must
  # stay enabled. Disabling it in favour of Entra-only auth would require a
  # user-delegation-key code path the driver does not implement.
  shared_access_key_enabled = true

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    # A window in which an accidental or malicious delete is recoverable.
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
    versioning_enabled = true
  }

  network_rules {
    # Reachable only from the Container Apps subnet. `default_action = Deny`
    # with no ip_rules means there is no public path to the blobs at all; the
    # only door is the app, and the app is inside the VNet.
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.apps.id]
  }

  tags = var.tags
}

resource "azurerm_storage_container" "uploads" {
  name                  = local.blob_container
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}
