variable "name_prefix" {
  description = "Prefix for every resource name. Lowercase letters and digits; keep it short — the storage account and registry names are derived from it and Azure caps those at 24 characters with no separators."
  type        = string
  default     = "quackback"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 chars, lowercase alphanumeric, starting with a letter."
  }
}

variable "location" {
  description = "Azure region for every resource."
  type        = string
  default     = "westeurope"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = { application = "quackback" }
}

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------

variable "image_tag" {
  description = "Container image tag to deploy. The CI workflow overrides this per release; pin it for a manual apply."
  type        = string
  default     = "latest"
}

variable "custom_domain" {
  description = "Public hostname, if you front the app with your own domain. Empty means the app is served on the Container Apps default FQDN, and BASE_URL is derived from it."
  type        = string
  default     = ""
}

variable "secret_key" {
  description = "Session signing + encryption key. MUST be >= 32 chars — generate with `openssl rand -base64 32`. Leave empty to have Terraform generate one into Key Vault."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.secret_key == "" || length(var.secret_key) >= 32
    error_message = "secret_key must be at least 32 characters."
  }
}

variable "trusted_proxy_hops" {
  description = <<-EOT
    Number of reverse proxies in front of the app, used to pick the real client
    IP out of X-Forwarded-For.

    Container Apps ingress alone is 1 hop. Put Front Door or another CDN in
    front and it becomes 2. Getting this wrong is not cosmetic: too low and
    every request appears to come from the proxy, which collapses rate limiting
    onto one bucket; too high and a client can spoof its own address by sending
    an X-Forwarded-For header.
  EOT
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Compute sizing
# ---------------------------------------------------------------------------

variable "web_min_replicas" {
  description = "Minimum web replicas. 1 avoids cold starts; 0 is possible but the first request then pays full boot."
  type        = number
  default     = 1
}

variable "web_max_replicas" {
  description = "Maximum web replicas. Keep web_max + worker_max under the connection budget — see the note on db_max_connections."
  type        = number
  default     = 10
}

variable "worker_max_replicas" {
  description = <<-EOT
    Maximum worker replicas.

    The worker tier's minimum is fixed at 1 and is not configurable: the
    scheduled sweeps are `setInterval` timers inside a running process
    (`lib/server/startup.ts`), so a worker scaled to zero does not defer its
    background work — it simply never runs it.
  EOT
  type        = number
  default     = 2
}

variable "web_cpu" {
  description = "vCPU per web replica. Container Apps requires cpu/memory to come from a fixed set of pairs (0.5/1Gi, 1/2Gi, 2/4Gi, ...)."
  type        = number
  default     = 1
}

variable "web_memory" {
  description = "Memory per web replica, paired with web_cpu."
  type        = string
  default     = "2Gi"
}

variable "worker_cpu" {
  description = "vCPU per worker replica."
  type        = number
  default     = 1
}

variable "worker_memory" {
  description = "Memory per worker replica, paired with worker_cpu."
  type        = string
  default     = "2Gi"
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

variable "postgres_sku" {
  description = "Flexible Server SKU. GP_Standard_D2s_v3 is a reasonable production floor; B_Standard_B1ms is for evaluation only."
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "postgres_storage_mb" {
  description = "Flexible Server storage in MB. Can be grown later, never shrunk."
  type        = number
  default     = 32768
}

variable "postgres_version" {
  description = "PostgreSQL major version. The bundled self-host image is 18; 16+ is required for the schema."
  type        = string
  default     = "16"
}

variable "postgres_admin_username" {
  description = "Administrator login. The app runs as this user because it issues CREATE EXTENSION for vector and pg_trgm on migrate."
  type        = string
  default     = "quackback"
}

variable "db_max_connections" {
  description = <<-EOT
    Postgres max_connections.

    This is a real ceiling on how far the app can scale out, not a tuning knob.
    Each replica opens up to DB_POOL_MAX connections, and the realtime listener
    holds one *additional* direct connection per replica, so the budget is
    roughly:

      (web_max + worker_max) * (db_pool_max + 1) + headroom < max_connections

    Exceed it and new replicas fail to connect under exactly the load that
    caused them to be created.
  EOT
  type        = number
  default     = 200
}

variable "db_pool_max" {
  description = "DB_POOL_MAX per replica. See db_max_connections for the arithmetic that constrains it."
  type        = number
  default     = 10
}

variable "postgres_backup_retention_days" {
  description = "Point-in-time restore window, in days."
  type        = number
  default     = 14
}

variable "postgres_geo_redundant_backup" {
  description = "Whether backups are geo-replicated. Cannot be changed after creation."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = string
  default     = "10.30.0.0/16"
}

variable "apps_subnet_prefix" {
  description = "Subnet delegated to the Container Apps environment. Azure requires at least a /23 for a workload-profiles environment."
  type        = string
  default     = "10.30.0.0/23"
}

variable "postgres_subnet_prefix" {
  description = "Subnet delegated to Flexible Server. Must be dedicated — Azure refuses to share a delegated database subnet."
  type        = string
  default     = "10.30.2.0/24"
}

# ---------------------------------------------------------------------------
# Email / AI (optional)
# ---------------------------------------------------------------------------

variable "email_from" {
  description = "From address for invites, magic links and notifications, e.g. 'Quackback <noreply@example.com>'. Empty logs emails to stdout instead of sending."
  type        = string
  default     = ""
}

variable "email_smtp_host" {
  description = "SMTP host. Azure Communication Services Email exposes one; any provider works."
  type        = string
  default     = ""
}

variable "email_smtp_port" {
  description = "SMTP port."
  type        = number
  default     = 587
}

variable "email_smtp_user" {
  description = "SMTP username."
  type        = string
  default     = ""
}

variable "email_smtp_password" {
  description = "SMTP password. Stored in Key Vault, never in an env var on the container."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_api_key" {
  description = "API key for AI features (summaries, duplicate detection, extraction). Empty disables them. For Azure OpenAI, set this to the resource key and openai_base_url to the deployment endpoint."
  type        = string
  sensitive   = true
  default     = ""
}

variable "openai_base_url" {
  description = "OpenAI-compatible base URL. Point at Azure OpenAI to keep inference inside Azure."
  type        = string
  default     = ""
}
