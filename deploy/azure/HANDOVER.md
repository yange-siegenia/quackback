# Azure deployment — handover

Status as of **2026-09-04**. This is a point-in-time note: what exists, what is
verified, and what the next person has to do. For how the deployment actually
works, read [`README.md`](./README.md) instead — this file deliberately does not
repeat it.

> Subscription IDs, tenant IDs and admin contact details are intentionally not
> recorded here, because this repository is a public fork. Recover them with
> `az account show`.

## One-line summary

The code and infrastructure are finished and pushed. Nothing has been deployed
yet, because a subscription-level Azure permission is missing and must be
granted by an administrator.

## The blocker

`Microsoft.DBforPostgreSQL` is **not registered** on the subscription.

```bash
az provider show -n Microsoft.DBforPostgreSQL --query registrationState -o tsv
# NotRegistered   <- as of this writing
# Registering     <- an admin has run it; takes a few minutes
# Registered      <- you are unblocked
```

Registration is a subscription-scope write. Holding Contributor on the target
resource group is not enough. It is free, creates no resources, changes no
billing, and is reversible — worth saying explicitly, because the request tends
to be read as "please provision a database".

Until it is `Registered`, `terraform apply` fails when it reaches the Postgres
resource, with an unhelpful API-version error that does not mention
registration.

A second, *optional* grant — `User Access Administrator` on the target resource
group — would remove the two-pass apply described below. Not required.

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
  subscription**. Plan sizes: 29 resources (defaults), 25 (adopting an existing
  resource group, no role assignments), 24 (also `combined_role = true`).

**Not verified:**

- `terraform apply` has **never been run**. No Azure resource has been created.
- The GitHub Actions workflows have **never been run**.

Expect the first apply and the first workflow run to surface something. That is
normal and is the honest state of things, not a defect.

## Next actions, in order

1. **Get the provider registered.** Chase the admin. Poll with the command
   above.

2. **Create the Terraform state backend** — a storage account plus a `tfstate`
   container, so state is shared rather than stranded on one laptop. Commands
   are in `README.md` under "One-time".

3. **Write `terraform.tfvars`.** Start from `terraform.tfvars.small.example`
   (this workload is roughly 20 feedback items per year, so the small profile is
   the right one) and set:

   ```hcl
   create_resource_group   = false          # the RG already exists
   resource_group_name     = "rg-quackback-test-01"
   location                = "germanywestcentral"
   manage_role_assignments = false          # unless User Access Administrator was granted
   combined_role           = true           # web + worker in one container app
   ```

4. **`terraform apply`.** Roughly ten minutes, mostly Postgres provisioning.

   **It is expected to stop at the Key Vault secrets** when
   `manage_role_assignments = false`. This is the documented two-pass flow, not
   a failure. Terraform prints the exact scopes and principal IDs as outputs; an
   admin runs three `az role assignment create` commands (see `README.md`), then
   you re-run apply and it completes.

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
