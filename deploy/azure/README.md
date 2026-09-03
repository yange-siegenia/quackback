# Quackback on Azure

A cloud-native deployment: each concern is a managed Azure service rather than a
process on one VM.

| Concern            | Azure service                        | Notes                                                    |
| ------------------ | ------------------------------------ | -------------------------------------------------------- |
| Web tier           | Container Apps (external ingress)    | `QUACKBACK_ROLE=web`, autoscales on HTTP concurrency      |
| Background tier    | Container Apps (no ingress)          | `QUACKBACK_ROLE=worker`, **min 1 replica**                |
| Migrations         | Container Apps **Job**               | One-shot, runs before each rollout                        |
| Database           | PostgreSQL Flexible Server (private) | `pgvector` + `pg_trgm`, private subnet, no public endpoint |
| Object storage     | Blob Storage (private container)     | Via the `azure_blob` storage driver                       |
| Secrets            | Key Vault                            | Read through a user-assigned managed identity             |
| Images             | Container Registry                   | Identity-based pulls; no admin user                       |
| Logs               | Log Analytics                        | The app already emits structured JSON                     |
| CI/CD              | GitHub Actions + OIDC                | No stored cloud credentials                                |

Everything lives in `deploy/azure/terraform/`.

---

## Why this shape

Quackback is already built for it — this deployment mostly *uses* structure that
already exists in the codebase rather than adding any.

- **The process roles are real.** `apps/web/src/lib/server/process-role.ts`
  splits `web` (serves HTTP, starts no background work) from `worker` (runs the
  queues and sweeps). Two container apps, one image.
- **There is no Redis, deliberately.** The job queue, cache, rate limiter,
  presence store and pub/sub all run on Postgres
  (`lib/server/kv/KV.md`, `lib/server/jobs/JOBS.md`). Do not add Azure Cache for
  Redis or Service Bus "to be cloud-native" — that would reverse a deliberate
  migration and add a datastore nothing reads.
- **Migrations were already externalizable.** The image honours
  `SKIP_MIGRATIONS=true`, which the Dockerfile explicitly documents as the
  Kubernetes/Jobs path.
- **Health probes already exist**: `/api/health/live` and `/api/health/ready`.

---

## Three things that will bite you

### 1. Never put the app behind a transaction-mode pooler

Realtime updates run on Postgres `LISTEN`/`NOTIFY`
(`lib/server/realtime/pubsub.ts`). A `LISTEN` issued through a transaction-mode
pooler *registers and then never delivers*. The failure is silent — HTTP keeps
working, live updates just stop.

So: connect directly on **5432**. There is no PgBouncer in this Terraform, and
adding one in front of the app would break realtime without any error.

The corollary is a scaling ceiling. Each replica opens up to `DB_POOL_MAX`
connections *plus one* direct connection for the listener:

```
(web_max_replicas + worker_max_replicas) * (db_pool_max + 1) + headroom
    < db_max_connections
```

Defaults: `(10 + 2) * 11 = 132` against `max_connections = 200`. Raise
`db_max_connections` (and the SKU) before raising the replica ceilings.

### 2. The worker cannot scale to zero

The scheduled sweeps are `setInterval` timers inside a live process
(`lib/server/startup.ts`) — not external cron. A worker scaled to zero does not
defer that work, it never performs it. `min_replicas = 1` on the worker is
hardcoded rather than variable-driven for exactly this reason.

### 3. `TRUSTED_PROXY_HOPS` must match your actual topology

Container Apps ingress is **1** hop. Add Front Door or another CDN and it
becomes **2**. Too low and every request appears to come from the proxy, which
collapses rate limiting into a single bucket; too high and a client can spoof
its own IP with an `X-Forwarded-For` header.

---

## Object storage: the one code change

Azure Blob has **no S3-compatible API**, so unlike MinIO or R2 it cannot be
reached by pointing `S3_ENDPOINT` at it. This deployment adds a real driver:

- `apps/web/src/lib/server/storage/azure-blob.ts` — the five wire operations
- selected by `STORAGE_DRIVER=azure_blob` (default is `s3`, so existing
  installs are untouched)

Namespacing, workspace scoping, credential resolution and all ~36 call sites are
driver-independent and unchanged: the driver receives object names that
`composeNamespacedKey` has already composed and validated.

The `S3_*` variables keep their names under both drivers because they name
*roles*, not vendors:

| Variable               | Azure meaning                                        |
| ---------------------- | ---------------------------------------------------- |
| `S3_BUCKET`            | blob container                                        |
| `S3_ACCESS_KEY_ID`     | storage account name                                  |
| `S3_SECRET_ACCESS_KEY` | storage account key                                   |
| `S3_ENDPOINT`          | blob endpoint (defaults to the public-cloud hostname) |
| `S3_REGION`            | **unused** — leave it unset                           |

The container is private; uploads are served through the app's `/api/storage`
route (`S3_PROXY=true`), which mints a short-lived SAS and redirects.

For local development against the Azurite emulator, set `S3_ENDPOINT` to
`http://127.0.0.1:10000/devstoreaccount1`. The driver notices the `http://`
scheme and widens the SAS protocol accordingly — an HTTPS-only SAS fetched over
HTTP is rejected with a 403.

---

## Deploying

### One-time

1. **Remote state.** Create a storage account and a `tfstate` container. The
   state holds the database password and the session signing key — keep it
   private.

2. **OIDC federation.** Register an app, federate it with this repository, and
   grant it Contributor + Role Based Access Control Administrator on the
   subscription (the latter is needed because Terraform creates role
   assignments).

3. **Repository variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID`, `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT`.

4. **Provision:**

   ```bash
   cd deploy/azure/terraform
   cp terraform.tfvars.example terraform.tfvars   # then edit
   terraform init \
     -backend-config="resource_group_name=<rg>" \
     -backend-config="storage_account_name=<sa>" \
     -backend-config="container_name=tfstate" \
     -backend-config="key=quackback.tfstate"
   terraform apply
   ```

5. **Feed the outputs back** as repository variables, so the deploy workflow can
   find what Terraform built:

   ```bash
   terraform output -raw registry_name         # -> AZURE_REGISTRY
   terraform output -raw resource_group_name   # -> AZURE_RESOURCE_GROUP
   terraform output -raw web_app_name          # -> AZURE_WEB_APP
   terraform output -raw worker_app_name       # -> AZURE_WORKER_APP
   terraform output -raw migration_job_name    # -> AZURE_MIGRATE_JOB
   ```

> The first `apply` creates the apps pointing at an image tag that does not
> exist yet; they stay unhealthy until the first deploy pushes one.

### Every release

Push a `v*` tag, or dispatch **Deploy to Azure** manually. The workflow:

1. builds the image (widget first — `apps/web` imports its bundle via `?raw`),
2. pushes to ACR,
3. runs the migration Job **and refuses to deploy if it fails**,
4. rolls web, then worker,
5. polls `/api/health/ready` and fails the run if it never turns 200.

Migrations run as a Job rather than from the runner because Postgres has no
public endpoint — CI genuinely cannot reach it. It also means the schema is
migrated once by one process rather than raced by every starting replica.

### Infrastructure changes

`Azure Infrastructure` plans on any PR touching `deploy/azure/terraform/**` and
comments the plan. Apply is a manual dispatch only — never automatic on merge,
because a plan here can destroy a database.

---

## Operational notes

**Seeding the first instance.** The image seeds when `SEED_DATABASE=true`. Run
it once via the migration job:

```bash
az containerapp job start -n <job> -g <rg> \
  --env-vars SEED_DATABASE=true
```

**Backups.** Flexible Server does point-in-time restore for
`postgres_backup_retention_days` (default 14). Blob has 30-day soft delete and
versioning. Neither covers `secret_key` — back that up separately, because
losing it invalidates every session and makes encrypted columns unreadable.

**Custom domain.** Set `custom_domain`, point a CNAME at the `web_fqdn` output,
then add the domain and a managed certificate to the web container app. `BASE_URL`
follows `custom_domain` automatically — it drives auth callbacks and email links,
so it must match what users actually type.

**Long-lived SSE connections.** Chat and inbox updates stream over SSE. The app
sends its own heartbeats (`lib/server/realtime/stream-heartbeat.ts`), which keeps
them under the Container Apps idle timeout.

**pg_cron is not required.** The bundled compose file preloads it only for
backwards compatibility with existing self-host volumes; scheduling lives in the
app's job tier. `azure.extensions` therefore allows only `VECTOR` and `PG_TRGM`,
which are the two the migration runner actually creates.

**Scaling the web tier** is safe within the connection budget above. Scaling the
worker adds queue throughput; the periodic sweeps hold a cross-instance sweep
lock, so extra workers do not duplicate them.
