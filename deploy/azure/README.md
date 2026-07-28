# Deploy Quackback to Azure (single VM)

Infrastructure-as-Code for standing up **one** Quackback instance on an Azure VM,
using the supported self-host stack ([`docker-compose.prod.yml`](../../docker-compose.prod.yml):
app + PostgreSQL + Dragonfly + MinIO) with **Caddy** in front for automatic HTTPS.

This is the least-effort path for a throwaway/test deployment (e.g. intern use):
everything runs on a single box, there are no managed data services to configure,
and it tears down cleanly. For larger or long-lived deployments, see the
[Self-Hosted Guide](../self-hosted/README.md).

## What gets created

Into an **existing resource group**:

- Virtual network + subnet
- Network security group — inbound `22` (SSH, source configurable), `80`, `443`
- Static public IP with a DNS label → `<dnsLabelPrefix>.<region>.cloudapp.azure.com`
- Ubuntu 24.04 LTS VM (default `Standard_B2s`, 64 GB StandardSSD)

On first boot, [`cloud-init.yaml`](./cloud-init.yaml) installs Docker, clones
Quackback, writes a hardened `.env` (secrets injected at deploy time), and starts
the stack behind Caddy via a `systemd` unit so it survives reboots.

## Prerequisites

- An Azure subscription and an **existing resource group**
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`)
- An SSH key pair (`ssh-keygen -t ed25519` if you don't have one)

## Deploy

```bash
cd deploy/azure

# 1. Copy the example params and edit dnsLabelPrefix + acmeEmail (and SMTP, optionally).
cp main.parameters.example.json main.parameters.json

# 2. Log in and select your subscription.
az login
az account set --subscription "<subscription-id-or-name>"

# 3. Deploy into your existing resource group.
az deployment group create \
  --resource-group "<your-rg>" \
  --template-file main.bicep \
  --parameters @main.parameters.json \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

The deployment prints the site URL and SSH command as outputs:

```bash
az deployment group show \
  --resource-group "<your-rg>" \
  --name main \
  --query properties.outputs
```

> **First boot takes a few minutes** while cloud-init installs Docker and pulls
> images, and Caddy needs a moment to obtain a TLS certificate. Give it ~5
> minutes before the site responds on HTTPS.

## Parameters

| Parameter                | Required | Default                            | Notes |
| ------------------------ | -------- | ---------------------------------- | ----- |
| `dnsLabelPrefix`         | ✅       | —                                  | Must be globally unique in the region. Forms the FQDN / `BASE_URL`. |
| `acmeEmail`              | ✅       | —                                  | Used by Caddy/Let's Encrypt for cert registration. |
| `adminSshPublicKey`      | ✅       | —                                  | Pass via `--parameters adminSshPublicKey=...` (password auth is disabled). |
| `sshSourceAddressPrefix` |          | `Internet`                         | **Tighten this** to your IP, e.g. `203.0.113.4/32`. |
| `vmSize`                 |          | `Standard_B2s`                     | Use `Standard_B2ms` (8 GB) if AI features are enabled. |
| `quackbackTag`           |          | `latest`                           | Pin to a release (e.g. `0.10.6`) for stability. |
| `adminUsername`          |          | `azureuser`                        | VM login user. |
| `secretKey`              |          | auto-generated                     | Session signing key (>= 32 chars). |
| `postgresPassword`       |          | auto-generated                     | Postgres password. |
| `minioPassword`          |          | auto-generated                     | MinIO root password (doubles as S3 secret). |
| `emailSmtpHost` / `...Port` / `...User` / `emailSmtpPass` / `emailFrom` | | blank | Configure SMTP so invites & magic-link login emails send. Left blank, login codes only appear in container logs. |

Auto-generated secrets use GUIDs so a hands-off deploy is fully self-configuring.
Supply your own values for `secretKey` / `postgresPassword` / `minioPassword` if
you want to control them.

## After it's up

1. Browse to the printed HTTPS URL and complete first-run setup.
2. If you didn't configure SMTP, grab your login code from the logs:
   ```bash
   ssh azureuser@<fqdn>
   cd /opt/quackback/quackback
   sudo docker compose -f docker-compose.prod.yml -f /opt/quackback/docker-compose.caddy.yml logs -f app
   ```
3. Invite your interns from the app.

## Operations

```bash
# SSH in
ssh azureuser@<fqdn>

# Stack status / logs
sudo systemctl status quackback
cd /opt/quackback/quackback
sudo docker compose -f docker-compose.prod.yml -f /opt/quackback/docker-compose.caddy.yml ps

# Upgrade (migrations run automatically on startup)
sudo git -C /opt/quackback/quackback pull
sudo docker compose -f docker-compose.prod.yml -f /opt/quackback/docker-compose.caddy.yml pull
sudo systemctl restart quackback
```

## Tear down

Deleting the resource group removes everything (VM, disk, IP, network) and stops
all billing:

```bash
az group delete --resource-group "<your-rg>"
```

To delete only the resources this template created while keeping the resource
group, delete the `quackback-*` resources individually.

## Notes & caveats

- **Single node by design.** Data lives in Docker volumes on the VM's disk. Take
  Postgres backups (`pg_dump`) before upgrades — see the
  [Self-Hosted Guide](../self-hosted/README.md#database-backups).
- **DNS/TLS.** Caddy issues a certificate for the `*.cloudapp.azure.com` FQDN out
  of the box. To use a custom domain, point a CNAME at the FQDN, set that domain
  in `/opt/quackback/Caddyfile`, and update `BASE_URL` in `.env`, then restart.
- **Object storage.** Uploads are served through the app's private MinIO
  (`S3_PROXY=true`); Azure Blob is not S3-compatible, so the bundled MinIO is used.
