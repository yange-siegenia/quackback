output "app_url" {
  description = "Public URL of the Quackback web tier. Set this as BASE_URL if you later move to a custom domain."
  value       = local.base_url
}

output "web_fqdn" {
  description = "Default Container Apps hostname for the web tier — the CNAME target for a custom domain."
  value       = azurerm_container_app.web.ingress[0].fqdn
}

output "registry_login_server" {
  description = "Container registry host. The deploy workflow pushes `<this>/quackback:<tag>`."
  value       = azurerm_container_registry.main.login_server
}

output "registry_name" {
  description = "Container registry name, for `az acr login`."
  value       = azurerm_container_registry.main.name
}

output "resource_group_name" {
  description = "Resource group holding every resource in this deployment."
  value       = local.resource_group_name
}

output "migration_job_name" {
  description = "Container Apps Job that runs database migrations. The deploy workflow starts this between pushing the image and rolling the apps."
  value       = azurerm_container_app_job.migrate.name
}

output "web_app_name" {
  description = "Name of the web container app, for `az containerapp update`."
  value       = azurerm_container_app.web.name
}

output "worker_app_name" {
  description = "Name of the worker container app, for `az containerapp update`. Empty when combined_role is true, because the web app is then also the worker and there is nothing separate to roll — the deploy workflow skips the worker step on an empty value."
  value       = var.combined_role ? "" : azurerm_container_app.worker[0].name
}

output "key_vault_name" {
  description = "Key Vault holding the application secrets."
  value       = azurerm_key_vault.main.name
}

output "postgres_fqdn" {
  description = "Private FQDN of the database. Resolvable only from inside the VNet, which is why migrations run as a Container Apps Job rather than from CI."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "storage_account_name" {
  description = "Storage account backing uploads."
  value       = azurerm_storage_account.main.name
}

output "database_url" {
  description = "Full connection string. Also stored in Key Vault as `database-url`."
  value       = local.database_url
  sensitive   = true
}

output "secret_key" {
  description = "Session signing key. Also stored in Key Vault as `secret-key`. Back this up: losing it invalidates every session and every encrypted column."
  value       = local.secret_key
  sensitive   = true
}

# ---------------------------------------------------------------------------
# For manage_role_assignments = false
#
# The three scope/principal pairs an administrator needs in order to grant the
# access Terraform was not permitted to grant itself. Printed unconditionally so
# they are available before the apply that needs them has succeeded.
# ---------------------------------------------------------------------------

output "app_identity_principal_id" {
  description = "Object ID of the user-assigned identity the containers run as. Needs AcrPull on the registry and Key Vault Secrets User on the vault."
  value       = azurerm_user_assigned_identity.app.principal_id
}

output "registry_id" {
  description = "Resource ID of the container registry — the scope for the app identity's AcrPull assignment."
  value       = azurerm_container_registry.main.id
}

output "key_vault_id" {
  description = "Resource ID of the key vault — the scope for both Key Vault role assignments."
  value       = azurerm_key_vault.main.id
}

output "deployer_principal_id" {
  description = "Object ID Terraform is authenticating as. Needs Key Vault Secrets Officer on the vault, or the apply cannot write secret values."
  value       = data.azurerm_client_config.current.object_id
}
