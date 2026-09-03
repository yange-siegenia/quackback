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
  value       = azurerm_resource_group.main.name
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
  description = "Name of the worker container app, for `az containerapp update`."
  value       = azurerm_container_app.worker.name
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
