# ============================================================================
# PostgreSQL Flexible Server
#
# Two things here are requirements of the application rather than preferences,
# and both are easy to lose in a later refactor:
#
#   1. `azure.extensions` must allow VECTOR and PG_TRGM. The migration runner
#      issues `CREATE EXTENSION` for both (packages/db/src/schema-ops.ts,
#      REQUIRED_EXTENSIONS). Azure refuses any extension not on this allowlist,
#      so without it the very first migration fails.
#
#   2. The app must connect **directly**, on 5432, never through a
#      transaction-mode pooler. Quackback's realtime layer is Postgres
#      LISTEN/NOTIFY (lib/server/realtime/pubsub.ts); a LISTEN issued through a
#      transaction-mode pooler registers and then never delivers. The failure is
#      silent — HTTP keeps working and live updates simply stop — so there is no
#      PgBouncer here on purpose.
#
# pg_cron is deliberately NOT enabled: scheduling lives in the application's own
# job tier (lib/server/jobs), and the bundled compose file preloads pg_cron only
# for backwards compatibility with existing self-host volumes.
# ============================================================================

resource "random_password" "postgres" {
  length  = 32
  special = true
  # Azure rejects these in a Postgres admin password.
  override_special = "!#%*()-_=+[]{}:?"
}

resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${var.name_prefix}-pg-${local.suffix}"
  resource_group_name = local.resource_group_name
  location            = local.location

  version                = var.postgres_version
  administrator_login    = var.postgres_admin_username
  administrator_password = random_password.postgres.result

  sku_name   = var.postgres_sku
  storage_mb = var.postgres_storage_mb

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  # Private access. There is no public endpoint and no firewall rule allowing
  # one; everything reaches the server from inside the VNet.
  delegated_subnet_id           = azurerm_subnet.postgres.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgres.id
  public_network_access_enabled = false

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]

  lifecycle {
    # Growing storage is allowed; shrinking is not, and Azure will not let a
    # later `terraform apply` quietly attempt it.
    prevent_destroy = false

    # Azure picks an availability zone at creation when none is requested, and
    # then reports it back. With no `zone` in the config the provider reads
    # that as a change to "" and refuses, because a zone can only be swapped
    # with a standby. Ignoring it keeps the server's assigned zone.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = local.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"

  lifecycle {
    prevent_destroy = false
  }
}

# The allowlist that makes `CREATE EXTENSION vector` and `CREATE EXTENSION
# pg_trgm` legal. Without this the first migration fails outright.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "VECTOR,PG_TRGM"
}

# See the db_max_connections variable for the arithmetic relating this to the
# replica ceilings.
resource "azurerm_postgresql_flexible_server_configuration" "max_connections" {
  name      = "max_connections"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = tostring(var.db_max_connections)
}

locals {
  # sslmode=require: Azure terminates TLS and rejects plaintext. The realtime
  # listener opens its own direct connection from this same URL, which is the
  # other half of "no pooler" — see the header comment.
  database_url = format(
    "postgresql://%s:%s@%s:5432/%s?sslmode=require",
    var.postgres_admin_username,
    urlencode(random_password.postgres.result),
    azurerm_postgresql_flexible_server.main.fqdn,
    local.database_name,
  )
}
