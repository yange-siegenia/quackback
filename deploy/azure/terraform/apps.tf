# ============================================================================
# Container Apps: the three roles
#
# Quackback's process model (apps/web/src/lib/server/process-role.ts) is what
# makes this a multi-service deployment rather than one box:
#
#   QUACKBACK_ROLE=web     serves HTTP and starts NO background work
#   QUACKBACK_ROLE=worker  runs the Postgres job queues and the periodic sweeps
#   (migrations)           a one-shot Job, run before a new revision rolls
#
# All three are the same image. Nothing here provisions a Redis or a message
# broker: the queue, cache, rate limiter, presence store and pub/sub all run on
# Postgres by design (lib/server/kv/KV.md), and adding a broker back would
# reverse a deliberate migration.
# ============================================================================

resource "azurerm_container_app_environment" "main" {
  name                = "${var.name_prefix}-env"
  resource_group_name = local.resource_group_name
  location            = local.resource_group_location

  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id

  # The app is internet-facing; only the *infrastructure* sits in the VNet, so
  # the datastores stay private while ingress stays public.
  internal_load_balancer_enabled = false

  tags = var.tags
}

locals {
  # The role the ingress-serving app runs as. Under combined_role it is also the
  # worker, and the separate worker app is not created.
  web_role = var.combined_role ? "all" : "web"

  # Combining forces a floor of 1: the sweeps are timers in a live process, so a
  # zero-replica app that is also the worker never runs them. Without this, a
  # deployment could set web_min_replicas = 0 for cold-start savings and
  # silently lose all background work.
  web_min_replicas = var.combined_role ? max(var.web_min_replicas, 1) : var.web_min_replicas

  # Non-secret configuration shared by every role.
  common_env = [
    { name = "PORT", value = "3000" },
    { name = "BASE_URL", value = local.base_url },
    { name = "LOG_LEVEL", value = "info" },
    { name = "DB_POOL_MAX", value = tostring(var.db_pool_max) },

    # Azure Blob, via the driver in lib/server/storage/azure-blob.ts.
    # S3_REGION is deliberately unset: Azure has no region parameter, and the
    # driver supplies an inert placeholder rather than making operators invent
    # a value that is never read.
    { name = "STORAGE_DRIVER", value = "azure_blob" },
    { name = "S3_BUCKET", value = azurerm_storage_container.uploads.name },
    { name = "S3_ACCESS_KEY_ID", value = azurerm_storage_account.main.name },
    { name = "S3_ENDPOINT", value = azurerm_storage_account.main.primary_blob_endpoint },
    # The container is private, so the browser cannot fetch blobs directly.
    # Uploads are served through the app's /api/storage route.
    { name = "S3_PROXY", value = "true" },
  ]

  optional_env = concat(
    var.email_from != "" ? [{ name = "EMAIL_FROM", value = var.email_from }] : [],
    var.email_smtp_host != "" ? [
      { name = "EMAIL_SMTP_HOST", value = var.email_smtp_host },
      { name = "EMAIL_SMTP_PORT", value = tostring(var.email_smtp_port) },
      { name = "EMAIL_SMTP_USER", value = var.email_smtp_user },
    ] : [],
    var.openai_base_url != "" ? [{ name = "OPENAI_BASE_URL", value = var.openai_base_url }] : [],
  )

  # Secrets, referenced by name; the values live in Key Vault.
  common_secret_env = concat(
    [
      { name = "DATABASE_URL", secret_name = "database-url" },
      { name = "SECRET_KEY", secret_name = "secret-key" },
      { name = "S3_SECRET_ACCESS_KEY", secret_name = "storage-account-key" },
    ],
    var.email_smtp_password != "" ? [{ name = "EMAIL_SMTP_PASS", secret_name = "smtp-password" }] : [],
    var.openai_api_key != "" ? [{ name = "OPENAI_API_KEY", secret_name = "openai-api-key" }] : [],
  )

  image = "${azurerm_container_registry.main.login_server}/quackback:${var.image_tag}"
}

# ---------------------------------------------------------------------------
# Web tier
# ---------------------------------------------------------------------------

resource "azurerm_container_app" "web" {
  name                         = "${var.name_prefix}-web"
  resource_group_name          = local.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  dynamic "secret" {
    for_each = local.enabled_secrets
    content {
      name = secret.value
      # Versionless, so a rotated secret is picked up on the next revision
      # without a Terraform change.
      key_vault_secret_id = azurerm_key_vault_secret.app[secret.value].versionless_id
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = local.web_min_replicas
    max_replicas = var.web_max_replicas

    container {
      name   = "web"
      image  = local.image
      cpu    = var.web_cpu
      memory = var.web_memory

      dynamic "env" {
        for_each = concat(local.common_env, local.optional_env)
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.common_secret_env
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }

      env {
        name  = "QUACKBACK_ROLE"
        value = local.web_role
      }

      # Migrations run in the Job below, before this revision rolls. Leaving
      # them on startup would put a schema migration on the cold-start path of
      # every replica and let two replicas race the same migration.
      env {
        name  = "SKIP_MIGRATIONS"
        value = "true"
      }

      env {
        name  = "TRUSTED_PROXY_HOPS"
        value = tostring(var.trusted_proxy_hops)
      }

      liveness_probe {
        transport = "HTTP"
        port      = 3000
        path      = "/api/health/live"

        initial_delay           = 10
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        port      = 3000
        path      = "/api/health/ready"

        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }
    }

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 50
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_role_assignment.kv_app_read]
}

# ---------------------------------------------------------------------------
# Worker tier
# ---------------------------------------------------------------------------

resource "azurerm_container_app" "worker" {
  count = var.combined_role ? 0 : 1

  name                         = "${var.name_prefix}-worker"
  resource_group_name          = local.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  dynamic "secret" {
    for_each = local.enabled_secrets
    content {
      name                = secret.value
      key_vault_secret_id = azurerm_key_vault_secret.app[secret.value].versionless_id
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  # No ingress block: the worker serves no traffic. Its health probes are
  # omitted for the same reason — Container Apps only probes ingress-enabled
  # apps, and the process exits on an unrecoverable boot failure.

  template {
    # Fixed at 1, not var-driven, and this is a correctness constraint rather
    # than a cost decision: the scheduled sweeps are setInterval timers inside a
    # live process (lib/server/startup.ts). A worker scaled to zero does not
    # defer that work, it never performs it.
    min_replicas = 1
    max_replicas = var.worker_max_replicas

    container {
      name   = "worker"
      image  = local.image
      cpu    = var.worker_cpu
      memory = var.worker_memory

      dynamic "env" {
        for_each = concat(local.common_env, local.optional_env)
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.common_secret_env
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }

      env {
        name  = "QUACKBACK_ROLE"
        value = "worker"
      }

      env {
        name  = "SKIP_MIGRATIONS"
        value = "true"
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_role_assignment.kv_app_read]
}

# ---------------------------------------------------------------------------
# Migration job
# ---------------------------------------------------------------------------

resource "azurerm_container_app_job" "migrate" {
  name                         = "${var.name_prefix}-migrate"
  resource_group_name          = local.resource_group_name
  location                     = local.resource_group_location
  container_app_environment_id = azurerm_container_app_environment.main.id
  tags                         = var.tags

  # Triggered by the deploy pipeline between building the image and rolling the
  # apps, never on a schedule.
  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  replica_timeout_in_seconds = 1800
  replica_retry_limit        = 0

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  dynamic "secret" {
    for_each = local.enabled_secrets
    content {
      name                = secret.value
      key_vault_secret_id = azurerm_key_vault_secret.app[secret.value].versionless_id
      identity            = azurerm_user_assigned_identity.app.id
    }
  }

  template {
    container {
      name   = "migrate"
      image  = local.image
      cpu    = 0.5
      memory = "1Gi"

      # The entrypoint is bypassed on purpose.
      #
      # `QUACKBACK_ROLE=migrator` would be the obvious-looking choice and is the
      # wrong one: in this image that role runs the *fleet* migrator, which
      # reconciles many workspace databases against a control-plane registry
      # under pooled tenancy. A single-database deployment wants the plain
      # migration runner, which is what apps/web/docker-entrypoint.sh executes
      # as `bun /app/migrate.mjs`.
      command = ["bun", "/app/migrate.mjs"]

      env {
        name  = "MIGRATIONS_FOLDER"
        value = "/app/drizzle"
      }

      dynamic "env" {
        for_each = local.common_secret_env
        content {
          name        = env.value.name
          secret_name = env.value.secret_name
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull, azurerm_role_assignment.kv_app_read]
}
