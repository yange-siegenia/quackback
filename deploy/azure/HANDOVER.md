# Azure deployment — handover

Status as of **2026-09-07**. This is a point-in-time note: what exists, what is
verified, and what the next person has to do. For how the deployment actually
works, read [`README.md`](./README.md) instead — this file deliberately does not
repeat it.

> Subscription IDs, tenant IDs and admin contact details are intentionally not
> recorded here, because this repository is a public fork. Recover them with
> `az account show`.

## One-line summary

The infrastructure is **deployed and running** in West Europe. What remains is
three role assignments an administrator has to make, then building and pushing
the first container image.

## The blocker

Three **role assignments**. `Contributor` on a resource group cannot create
role assignments, so these cannot be self-served:

| Who | Role | Scope | Why |
| --- | --- | --- | --- |
| app managed identity | `AcrPull` | the container registry | pull images |
| app managed identity | `Key Vault Secrets User` | the key vault | read secrets at runtime |
| the deploying user | `Key Vault Secrets Officer` | the key vault | write secrets during apply |

`terraform apply` runs cleanly until the Key Vault secrets, then fails three
times with `403 ForbiddenByRbac` and `Assignment: (not found)`. That is the
documented two-pass flow, not a fault. Terraform exposes the exact scopes and
principal IDs as outputs; run `terraform output` to regenerate the commands.

Granting `User Access Administrator` on **only** the resource group would
remove this step permanently.

### Resolved: Postgres provider registration

`Microsoft.DBforPostgreSQL` was `NotRegistered` and has since been registered
by an administrator. Verify with:

```bash
az provider show -n Microsoft.DBforPostgreSQL --query registrationState -o tsv
```

## What is actually deployed

All in **West Europe**, inside the pre-existing `rg-quackback-test-01`
(which itself sits in Germany West Central — see the region note below):

| Resource | Name | State |
| --- | --- | --- |
| PostgreSQL Flexible Server | `quackback-pg-rjeec6` | running, `VECTOR,PG_TRGM` enabled, private only |
| Container Registry | `quackbackacrrjeec6` | running, empty — no image pushed yet |
| Key Vault | `quackback-kv-8589re` | created, **secrets not yet written** |
| Container Apps environment | `quackback-env` | running |
| Storage account + container | `quackbackstrjeec6` | running |
| Managed identity | `quackback-identity` | created |
| VNet + subnets + private DNS | `quackback-vnet-rjeec6` | running |
| Log Analytics | `quackback-logs` | running |
| Web app / migration job | `quackback-web`, `quackback-migrate` | **not yet created** — blocked on secrets |

Terraform state lives in `stqbtfstate2b798dfd`, container `tfstate`, with blob
versioning and 30-day soft delete enabled.

> **Authentication note.** The state backend is accessed with the storage
> account key (`ARM_ACCESS_KEY`), not AAD. `Contributor` is a management-plane
> role and does not grant blob data-plane access, so `use_azuread_auth` fails
> with `AuthorizationPermissionMismatch`. Listing the key is permitted.

> **MFA note.** This tenant enforces a Conditional Access authentication
> context (`acrs: p1`) on management writes. Reads succeed without it, so the
> failure only appears at the first write. `az` caches tokens *per audience*,
> and Terraform uses `management.azure.com` while `az` may have only stepped up
> `management.core.windows.net`. If writes 401 with `RequestDisallowedByAzure`:
>
> ```bash
> az account clear
> az login --use-device-code --scope "https://management.azure.com/.default" \
>   --claims-challenge "eyJhY2Nlc3NfdG9rZW4iOnsiYWNycyI6eyJlc3NlbnRpYWwiOnRydWUsInZhbHVlcyI6WyJwMSJdfX19"
> ```

## Why West Europe and not Germany

Postgres Flexible Server is **capacity-restricted in Germany West Central** for
this subscription: the capabilities API reports `restricted: Enabled` and
offers no Burstable SKUs at all. The failure surfaces late and cryptically as
`the value of 'Version' should be in: []`.

Azure permits resources to live in a different region from their resource
group, so only `location` changed. West Europe is the Netherlands — still EU,
so the GDPR position is unchanged.

**If German data residency is a hard requirement**, this is the wrong choice
and should be revisited before real data exists. The alternative is a support
request (issue type "Service and subscription limits") to lift the restriction
in Germany West Central.

## What was built

| Area | Where | Notes |
| --- | --- | --- |
| Azure Blob storage driver | `apps/web/src/lib/server/storage/azure-blob.ts` | The one genuine code gap. Azure Blob has no S3-compatible API, so the existing S3 client cannot talk to it. Selected by config; S3 remains the default. |
| Driver tests | `.../storage/__tests__/azure-blob.test.ts` | 23 tests, plus a manual end-to-end run against a live Azurite container. |
| Infrastructure | `deploy/azure/terraform/` | Postgres Flexible Server, Container Registry, Key Vault, Storage Account, Log Analytics, Container Apps (web, worker, migration job). |
| CI/CD | `.github/workflows/azure-deploy.yml`, `azure-infra.yml` | Build image, push to registry, run migrations, deploy new revision. |
| Docs | `deploy/azure/README.md` | Architecture, sizing, gotchas, VM decommissioning runbook. |

Two fixes were made along the way that are not about Azure:

- **`vitest.config.ts`** — the entire test suite could not run. Vite's SSR
  transform drops zod's `z` export given zod 4.4.3's particular re-export shape.
  Fixed by pre-bundling zod. Sent upstream as QuackbackIO/quackback#491.
  **That PR needs a CLA signature before it can merge.**
- **`policy/module-state/ledger.ts`** — the new driver introduced module-scope
  state, which the repo's policy test rejects unless it is declared.

## Verified vs. not verified

Be precise about this, because the gap is where the risk lives.

**Verified:**

- Full test suite passes — 13,946 tests, against a real `pgvector/pgvector:pg17`
  Postgres with migrations applied. (Five failures under parallelism all pass in
  isolation; they pre-date this work.)
- The Blob driver works end to end against a live Azurite container. This is how
  a real bug was caught: signed URLs hardcoded the HTTPS protocol and returned
  403 over plain HTTP. Reasoning about the code did not surface it; running it
  did.
- `terraform fmt`, `terraform validate`, and `terraform plan` against the **real
  subscription**.
- **`terraform apply` against the real subscription** — the infrastructure in
  the table above exists and is running. Four faults were found this way that
  every clean `plan` had missed; see commit `1384f138b`.

**Not verified:**

- The GitHub Actions workflows have **never been run**.
- No container image has been built or pushed, so the app has **never actually
  started**. Everything below the infrastructure layer is still unproven.
- The web app and migration job do not exist yet — they are blocked on the Key
  Vault secrets.

## Next actions, in order

1. **Get the three role assignments made.** See "The blocker" above. Regenerate
   the exact commands with `terraform output`.

2. **Re-run `terraform apply`.** It should complete, writing the three secrets
   and creating the web app and migration job.

3. **Build and push the first image.** The registry is empty, so the container
   app has nothing to run. Note the widget must be built *before* the web app —
   its `dist/browser.js` is imported via Vite `?raw`.

4. **Run the migration job** to create the schema:

   ```bash
   az containerapp job start -g rg-quackback-test-01 -n quackback-migrate
   ```

5. **Wire up GitHub Actions.** Set the repository variables from the Terraform
   outputs: `AZURE_REGISTRY`, `AZURE_RESOURCE_GROUP`, `AZURE_WEB_APP`,
   `AZURE_MIGRATE_JOB`, and `AZURE_WORKER_APP` — the last is **empty** when
   `combined_role = true`.

6. **Smoke test two things specifically**, because they are the two paths most
   likely to behave differently in Azure than locally:
   - a changelog image upload, which exercises the new Blob driver over the real
     network;
   - live-updating comments, which exercise Postgres `LISTEN`/`NOTIFY` through
     the real connection path.

7. **Retire the old VM.** See "Retiring a single-VM deployment" in `README.md`.

## If an apply crashes midway

It happened once here, from a transient DNS failure while writing state. The
dangerous part is not the failed resource — it is that Terraform may have
changed Azure without recording it, leaving state *behind reality*.

Terraform writes `errored.tfstate` in the working directory when this happens.
Do not run `apply` again first; that forks the state. Instead:

```bash
terraform state pull | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['serial'])"
python3 -c "import json;print(json.load(open('errored.tfstate'))['serial'])"
# if the local serial is higher, the remote is stale:
terraform force-unlock -force <LOCK_ID>   # the ID is printed by the failed run
terraform state push errored.tfstate
```

**Avoid saved plan files (`-out`) while iterating.** A saved plan encodes
decisions made against an earlier reality. One replaced the VNet without
recreating its subnets, because the VNet's *name* was unchanged — only its
region — so nothing in the plan marked the subnets as affected. Plain
`terraform apply` plans and applies atomically and does not have this problem.

## Things that will cost you if forgotten

- **Carry the existing `SECRET_KEY` into `terraform.tfvars`** if you are keeping
  the old deployment's data. A fresh key invalidates every session and makes
  encrypted columns permanently unreadable.
- **Deleting a VM does not delete its disk, NIC, public IP or NSG.** They remain
  as separate billable resources. Delete them explicitly.
- **Never put this app behind a transaction-mode connection pooler.** `LISTEN`
  registers successfully and then silently never delivers. Explained in
  `README.md`.
- **The worker cannot scale to zero.** Its sweeps are interval timers, so at
  zero replicas they do not run at all — they are not merely deferred.

## Cost, for reference

Checked against the Azure Retail Prices API (EUR, germanywestcentral), not
estimated:

- Postgres B1ms compute €12.48/mo + 32 GB storage €3.76/mo = **€16.25/mo**.
  Backups are free up to 100% of storage.
- The existing `quackback-vm` (Standard_B2s) is **€30.08/mo**, before its disk
  and public IP.

So the managed database costs about half of the VM it replaces. The Container
Apps consumption meters returned zero from the pricing API and remain
**unverified** — check the pricing calculator before quoting a total.
