#!/usr/bin/env bash
#
# Put a Container App behind Entra ID sign-in, so only accounts from your own
# tenant can reach it.
#
# Why this is a script and not Terraform: the azurerm provider does not manage
# Container Apps `authConfigs`. Because it does not manage them, it also does
# not destroy them — the configuration made here survives `terraform apply`.
#
# Usage:
#   ./enable-entra-auth.sh <resource-group> <container-app-name>
#
# Re-running is safe: it reuses the existing app registration if one is already
# named for this app, and only rotates the client secret.

set -euo pipefail

RG="${1:?usage: enable-entra-auth.sh <resource-group> <container-app-name>}"
APP="${2:?usage: enable-entra-auth.sh <resource-group> <container-app-name>}"

# `tr -d '\r'` throughout: under WSL the Windows az.cmd emits CRLF, and the
# stray CR silently corrupts every value it touches.
strip() { tr -d '\r'; }

DISPLAY_NAME="Quackback (${APP})"
SECRET_NAME="aad-client-secret"

TENANT=$(az account show --query tenantId -o tsv | strip)
FQDN=$(az containerapp show -g "$RG" -n "$APP" \
  --query "properties.configuration.ingress.fqdn" -o tsv | strip)

if [ -z "$FQDN" ]; then
  echo "error: '$APP' has no ingress FQDN — is external ingress enabled?" >&2
  exit 1
fi

REDIRECT_URI="https://${FQDN}/.auth/login/aad/callback"
echo "app:      $APP"
echo "tenant:   $TENANT"
echo "redirect: $REDIRECT_URI"

# --- app registration -------------------------------------------------------
# sign-in-audience AzureADMyOrg is what restricts this to your own tenant.
# Without it, any Microsoft account in the world could authenticate.
APP_ID=$(az ad app list --display-name "$DISPLAY_NAME" --query "[0].appId" -o tsv | strip)

if [ -z "$APP_ID" ]; then
  echo "creating app registration..."
  APP_ID=$(az ad app create \
    --display-name "$DISPLAY_NAME" \
    --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "$REDIRECT_URI" \
    --enable-id-token-issuance true \
    --query appId -o tsv | strip)
  az ad sp create --id "$APP_ID" -o none
else
  echo "reusing existing app registration $APP_ID"
  az ad app update --id "$APP_ID" --web-redirect-uris "$REDIRECT_URI" -o none
fi

# --- client secret ----------------------------------------------------------
# Never echoed. It goes straight into the container app's secret store.
echo "issuing client secret..."
SECRET=$(az ad app credential reset \
  --id "$APP_ID" --display-name easyauth --years 2 \
  --query password -o tsv | strip)

az containerapp secret set -g "$RG" -n "$APP" \
  --secrets "${SECRET_NAME}=${SECRET}" -o none
unset SECRET

# --- auth configuration -----------------------------------------------------
# The v2.0 issuer already pins the tenant; passing --tenant-id as well is
# rejected as a conflict.
az containerapp auth microsoft update -g "$RG" -n "$APP" \
  --client-id "$APP_ID" \
  --client-secret-name "$SECRET_NAME" \
  --issuer "https://login.microsoftonline.com/${TENANT}/v2.0" \
  --allowed-audiences "api://${APP_ID}" \
  --yes -o none

az containerapp auth update -g "$RG" -n "$APP" \
  --enabled true \
  --action RedirectToLoginPage \
  --redirect-provider azureactivedirectory \
  --require-https true -o none

# A secret added to an already-running revision is not picked up until the
# revision restarts. Skip this and the auth sidecar cannot resolve the secret
# and every request 503s.
REVISION=$(az containerapp show -g "$RG" -n "$APP" \
  --query "properties.latestRevisionName" -o tsv | strip)
echo "restarting revision $REVISION so it picks up the secret..."
az containerapp revision restart -g "$RG" -n "$APP" --revision "$REVISION" -o none

echo
echo "done. verify with:"
echo "  curl -sI https://${FQDN}/ | head -1                         # expect 401"
echo "  curl -sI -H 'Accept: text/html' https://${FQDN}/ | head -1  # expect 302"
