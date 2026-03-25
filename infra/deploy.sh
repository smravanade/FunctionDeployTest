#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh – Provision Azure resources for a containerised Python Function App
#
# Minimum-cost choices:
#   • ACR:              Basic  SKU  (~$0.17 / day, free egress within Azure)
#   • Storage account:  Standard LRS (cheapest redundancy option)
#   • App Service Plan: Elastic Premium EP1 (smallest premium SKU)
#                       – scale-in to 0 when idle to reduce cost
#
# Usage:
#   export AZURE_SUBSCRIPTION_ID="<your-subscription-id>"   # optional
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Override defaults by setting env vars before running, e.g.:
#   LOCATION=westeurope ./deploy.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Configurable variables ──────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-funcapp-container}"
LOCATION="${LOCATION:-eastus}"
ACR_NAME="${ACR_NAME:-acrfuncapp$RANDOM}"          # must be globally unique
STORAGE_NAME="${STORAGE_NAME:-safuncapp$RANDOM}"   # must be globally unique, 3-24 lower-alphanumeric
PLAN_NAME="${PLAN_NAME:-asp-funcapp-ep1}"
FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-funcapp-container-$RANDOM}"
IMAGE_NAME="${IMAGE_NAME:-http-trigger}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
# ---------------------------------------------------------------------------

echo "=== Azure Function App – Container Deployment ==="
echo "Resource Group : $RESOURCE_GROUP"
echo "Location       : $LOCATION"
echo "ACR            : $ACR_NAME"
echo "Storage        : $STORAGE_NAME"
echo "Plan           : $PLAN_NAME"
echo "Function App   : $FUNCTION_APP_NAME"
echo ""

# 1. Set subscription (only if env var is provided)
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
fi

# 2. Resource group
echo "── Creating resource group..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

# 3. Azure Container Registry (Basic – lowest cost)
echo "── Creating ACR (Basic SKU)..."
az acr create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --sku Basic \
    --admin-enabled true \
    --output none

ACR_LOGIN_SERVER=$(az acr show \
    --name "$ACR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query loginServer \
    --output tsv)

echo "    ACR login server: $ACR_LOGIN_SERVER"

# 4. Build & push the container image via ACR Tasks (no local Docker required)
#    Assumes a Dockerfile exists at the repository root (one level above infra/).
echo "── Building and pushing image via ACR Tasks..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

az acr build \
    --registry "$ACR_NAME" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    "$REPO_ROOT"

FULL_IMAGE="${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
echo "    Image: $FULL_IMAGE"

# 5. Storage account (Standard LRS – cheapest option)
echo "── Creating storage account..."
az storage account create \
    --name "$STORAGE_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --output none

# 6. App Service Plan – Elastic Premium EP1 (minimum premium SKU)
#    maximum-elastic-worker-count=1 keeps scaling minimal to reduce cost
echo "── Creating Elastic Premium plan (EP1)..."
az functionapp plan create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PLAN_NAME" \
    --location "$LOCATION" \
    --sku EP1 \
    --is-linux \
    --output none

# 7. Function App (Linux container)
# NOTE: Admin credentials are used here for simplicity. For production workloads,
# replace with Managed Identity: assign the AcrPull role to the Function App's
# system-assigned identity and remove the --docker-registry-server-* credential flags.
echo "── Creating Function App..."
ACR_PASSWORD=$(az acr credential show \
    --name "$ACR_NAME" \
    --query "passwords[0].value" \
    --output tsv)

az functionapp create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --storage-account "$STORAGE_NAME" \
    --plan "$PLAN_NAME" \
    --deployment-container-image-name "$FULL_IMAGE" \
    --docker-registry-server-url "https://${ACR_LOGIN_SERVER}" \
    --docker-registry-server-user "$ACR_NAME" \
    --docker-registry-server-password "$ACR_PASSWORD" \
    --os-type Linux \
    --output none

# 8. Enable continuous deployment webhook from ACR
echo "── Enabling ACR → Function App continuous deployment webhook..."
CI_CD_URL=$(az functionapp deployment container config \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --enable-cd true \
    --query CI_CD_URL \
    --output tsv)

az acr webhook create \
    --registry "$ACR_NAME" \
    --name "funcappwebhook" \
    --uri "$CI_CD_URL" \
    --actions push \
    --output none

echo ""
echo "=== Deployment complete ==="
echo "Function App URL : https://${FUNCTION_APP_NAME}.azurewebsites.net"
echo "HTTP Trigger     : https://${FUNCTION_APP_NAME}.azurewebsites.net/api/http_trigger"
echo ""
echo "Save these values as GitHub Actions secrets:"
echo "  AZURE_FUNCTION_APP_NAME  = $FUNCTION_APP_NAME"
echo "  ACR_LOGIN_SERVER         = $ACR_LOGIN_SERVER"
echo "  ACR_NAME                 = $ACR_NAME"
echo "  AZURE_RESOURCE_GROUP     = $RESOURCE_GROUP"
