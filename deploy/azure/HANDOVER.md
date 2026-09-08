# Azure deployment — handover

Status as of **2026-09-08**. This is a point-in-time note: what exists, what is
verified, and what the next person has to do. For how the deployment actually
works, read [`README.md`](./README.md) instead — this file deliberately does not
repeat it.

> Subscription IDs, tenant IDs and admin contact details are intentionally not
> recorded here, because this repository is a public fork. Recover them with
> `az account show`.

## One-line summary

The application is **deployed, running and serving traffic** in West Europe,
behind Entra ID sign-in. Storage and migrations are proven against the real
infrastructure. What remains is CI/CD and decommissioning the old VM.

## The remaining blocker: CI/CD

GitHub Actions cannot be wired up without one more administrator action, for
the same reason as before: **`Contributor` cannot create role assignments.**

A deployment pipeline needs a principal that can push to the registry *and*
update the container app. The registry half can be self-served (enable the
registry admin user, or use a scoped token on a Premium registry). The
container-app half cannot — it requires a role assignment.

The cleanest fix is **`Owner` on `rg-quackback-test-01` alone**. It is a
one-time grant that removes this class of blocker permanently, and it is
consistent with the access already held on other resource groups. The
narrower alternative is `AcrPush` + `Contributor` for a deployment identity,
scoped to that resource group.

Note also that `az acr build` does **not** work from this environment — see
"Environment traps" below.

### Resolved: the three original role assignments

`AcrPull` and `Key Vault Secrets User` for the app identity, and
`Key Vault Secrets Officer` for the deploying user, have all been granted.
Verify by *writing* a secret, not by listing role assignments — the listing can
succeed while the data-plane call still fails.

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
| Container Registry | `quackbackacrrjeec6` | running, holds `quackback:latest` |
| Key Vault | `quackback-kv-8589re` | running, three secrets written |
| Container Apps environment | `quackback-env` | running |
| Storage account + container | `quackbackstrjeec6` | running |
| Managed identity | `quackback-identity` | created |
| VNet + subnets + private DNS | `quackback-vnet-rjeec6` | running |
| Log Analytics | `quackback-logs` | running |
| Web app | `quackback-web` | running, serving behind Entra ID sign-in |
| Migration job | `quackback-migrate` | last run `Succeeded` |

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
| CI/CD | `.github/workflows/azure-deploy.yml`, `azure-infra.yml` | Build image, push to registry, run migrations, deploy new revision. **Never yet run.** |
| Access control | `deploy/azure/scripts/enable-entra-auth.sh` | Puts the app behind Entra ID sign-in, restricted to this tenant. Not Terraform, because azurerm does not manage Container Apps `authConfigs`. |
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
- **The application serves traffic.** Migrations ran to `Succeeded`, and the app
  returned HTTP 200 on `/onboarding/account` before sign-in was enforced.
- **The Blob driver works in Azure**, not just against Azurite. A screenshot
  uploaded through the UI produced 59,422 bytes of blob *Ingress* and 59,107
  bytes of *Egress* in the same five-minute window, at 100% availability. Note
  that `az storage blob list` **cannot** be used to check this from a laptop —
  the storage account only accepts traffic from the app's subnet, so it fails
  with "request may be blocked by network rules". That is the network lock
  working, not a fault. Metrics are the way to verify from outside.
- **Entra ID sign-in is enforced.** Anonymous browser requests get `302` to
  `login.microsoftonline.com`; anonymous API requests get `401`.

**Not verified:**

- The GitHub Actions workflows have **never been run**, and cannot be until the
  CI/CD role assignment above is made.
- Live-updating comments (Postgres `LISTEN`/`NOTIFY`) have not been exercised
  over the real network path. This is the highest-value remaining smoke test.
- Container Apps running costs. The retail pricing API returned zero for the
  consumption meters.

## Access control

The app is **not publicly reachable**. It sits behind Container Apps built-in
authentication, backed by a dedicated app registration with
`signInAudience = AzureADMyOrg` and the issuer pinned to the tenant, so only
accounts from this tenant can sign in, from any network.

Reproduce or repair it with:

```bash
deploy/azure/scripts/enable-entra-auth.sh rg-quackback-test-01 quackback-web
```

Three things worth knowing:

- **This is a second login**, in front of Quackback's own. That is the accepted
  cost of tenant-level restriction.
- **It blocks the embeddable widget and any unauthenticated API use.** Chosen
  deliberately, because nothing embeds the widget. Revisit if that changes.
- **IP allowlisting was considered and rejected** — staff are not reliably on an
  office network, so an allowlist locks out legitimate users while doing less.

Terraform does not manage Container Apps `authConfigs`, so this survives
`terraform apply` untouched — but it also means Terraform will never recreate
it. If the app is rebuilt from scratch, re-run the script.

## Environment traps

These cost real time here, and will again.

- **`az acr build` does not work.** Under WSL with the *Windows* Azure CLI, it
  enumerates the source tree before applying `.dockerignore` and dies on
  Windows' 260-character path limit inside nested `node_modules`. Build and push
  locally instead:

  ```bash
  TOKEN=$(az acr login --name <registry> --expose-token \
    --query accessToken -o tsv | tr -d '\r')
  echo "$TOKEN" | docker login <registry>.azurecr.io \
    -u 00000000-0000-0000-0000-000000000000 --password-stdin
  docker build --platform linux/amd64 \
    -t <registry>.azurecr.io/quackback:latest -f apps/web/Dockerfile .
  docker push <registry>.azurecr.io/quackback:latest
  ```

- **Always pipe Windows `az` output through `tr -d '\r'`.** The trailing
  carriage return silently corrupts tokens, IDs and connection strings.

- **`--platform linux/amd64` is not optional** if the workstation is ARM.

- **A secret added to a running revision needs a revision restart.** Until then
  the platform cannot resolve it, and every request returns `503` while the
  revision still reports `Running`.

## Next actions, in order

1. **Smoke-test live-updating comments** — open the same post in two browsers
   and comment. This is the last unproven runtime path.

2. **Get the CI/CD permission granted**, then wire up GitHub Actions. Set the
   repository variables from the Terraform outputs: `AZURE_REGISTRY`,
   `AZURE_RESOURCE_GROUP`, `AZURE_WEB_APP`, `AZURE_MIGRATE_JOB`, and
   `AZURE_WORKER_APP` — the last is **empty** when `combined_role = true`.

3. **Retire the old VM.** It is still running and still billing, roughly €30/mo
   on top of the new stack. Its disk, NIC, public IP, NSG and the old
   `quackback-vnet` must be deleted explicitly — they do not cascade. See
   "Retiring a single-VM deployment" in `README.md`.

4. **Consider flipping `manage_role_assignments = true`** in `terraform.tfvars`
   now that the roles exist, so Terraform owns them going forward.

5. **Sign the CLA** on QuackbackIO/quackback#491 so the upstream vitest fix can
   merge.

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
