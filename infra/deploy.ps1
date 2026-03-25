# ---------------------------------------------------------------------------
# deploy.ps1 – Provision Azure resources for a containerised Python Function App
#
# Minimum-cost choices:
#   • ACR:              Basic  SKU  (~$0.17 / day, free egress within Azure)
#   • Storage account:  Standard LRS (cheapest redundancy option)
#   • App Service Plan: Elastic Premium EP1 (smallest premium SKU)
#                       – scale-in to 0 when idle to reduce cost
#
# Usage:
#   .\infra\deploy.ps1
#
# Override defaults by passing parameters, e.g.:
#   .\infra\deploy.ps1 -Location "westeurope"
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$TenantId            = "cf36141c-ddd7-45a7-b073-111f66d0b30c",
    [string]$SubscriptionId      = "e66b7b42-119f-40e9-a944-601f92058b7c",
    [string]$ResourceGroup       = "rg-funcapp-container",
    [string]$Location            = "eastus",
    [string]$AcrName             = "acrfuncapp7857",
    [string]$StorageName         = "safuncapp7857",
    [string]$PlanName            = "asp-funcapp-ep1",
    [string]$FunctionAppName     = "funcapp-container-7857",
    [string]$ImageName           = "http-trigger",
    [string]$ImageTag            = "latest",
    [string]$UamiName            = "github-actions-uami"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Makes native commands (e.g. az CLI) throw on non-zero exit codes (requires PowerShell 7.3+)
$PSNativeCommandUseErrorActionPreference = $true

Write-Host "=== Azure Function App – Container Deployment ===" -ForegroundColor Cyan
Write-Host "Resource Group : $ResourceGroup"
Write-Host "Location       : $Location"
Write-Host "ACR            : $AcrName"
Write-Host "Storage        : $StorageName"
Write-Host "Plan           : $PlanName"
Write-Host "Function App   : $FunctionAppName"
Write-Host ""

# 1. Log in to Azure
Write-Host "── Logging in to Azure..." -ForegroundColor Yellow
if ($TenantId -and $SubscriptionId) {
    az login --tenant $TenantId
    az account set --subscription $SubscriptionId
} elseif ($TenantId) {
    az login --tenant $TenantId
} elseif ($SubscriptionId) {
    az login
    az account set --subscription $SubscriptionId
} else {
    az login
}

# 2. Resource group
Write-Host "── Creating resource group..." -ForegroundColor Yellow
az group create `
    --name $ResourceGroup `
    --location $Location `
    --output none

# 2b. User-Assigned Managed Identity (for GitHub Actions OIDC)
Write-Host "── Creating User-Assigned Managed Identity ($UamiName)..." -ForegroundColor Yellow
az identity create `
    --name $UamiName `
    --resource-group $ResourceGroup `
    --location $Location `
    --output none

$UamiClientId    = az identity show --name $UamiName --resource-group $ResourceGroup --query clientId    --output tsv
$UamiPrincipalId = az identity show --name $UamiName --resource-group $ResourceGroup --query principalId --output tsv
$RgScope         = az group show    --name $ResourceGroup                              --query id          --output tsv

Write-Host "── Assigning Owner on resource group to UAMI (required to create role assignments)..." -ForegroundColor Yellow
az role assignment create `
    --role Owner `
    --assignee-object-id $UamiPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --scope $RgScope `
    --output none

# 3. Azure Container Registry (Basic – lowest cost)
Write-Host "── Creating ACR (Basic SKU)..." -ForegroundColor Yellow
az acr create `
    --resource-group $ResourceGroup `
    --name $AcrName `
    --sku Basic `
    --admin-enabled true `
    --output none

$AcrLoginServer = az acr show `
    --name $AcrName `
    --resource-group $ResourceGroup `
    --query loginServer `
    --output tsv

Write-Host "    ACR login server: $AcrLoginServer"

Write-Host "── Assigning AcrPush on ACR to UAMI..." -ForegroundColor Yellow
$AcrScope = az acr show --name $AcrName --resource-group $ResourceGroup --query id --output tsv
az role assignment create `
    --role AcrPush `
    --assignee-object-id $UamiPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --scope $AcrScope `
    --output none

# 4. Build & push the container image via ACR Tasks (no local Docker required)
#    Dockerfile is expected at the repository root (one level above infra/).
Write-Host "── Building and pushing image via ACR Tasks..." -ForegroundColor Yellow
$RepoRoot = Split-Path -Parent $PSScriptRoot

az acr build `
    --registry $AcrName `
    --image "${ImageName}:${ImageTag}" `
    $RepoRoot

$FullImage = "${AcrLoginServer}/${ImageName}:${ImageTag}"
Write-Host "    Image: $FullImage"

# 5. Storage account (Standard LRS – cheapest option)
Write-Host "── Creating storage account..." -ForegroundColor Yellow
az storage account create `
    --name $StorageName `
    --resource-group $ResourceGroup `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --output none

# 6. App Service Plan – Elastic Premium EP1 (minimum premium SKU)
#    maximum-elastic-worker-count=1 keeps scaling minimal to reduce cost
Write-Host "── Creating Elastic Premium plan (EP1)..." -ForegroundColor Yellow
az functionapp plan create `
    --resource-group $ResourceGroup `
    --name $PlanName `
    --location $Location `
    --sku EP1 `
    --is-linux `
    --output none

# 7. Function App (Linux container)
# NOTE: Admin credentials are used here for simplicity. For production workloads,
# replace with Managed Identity: assign the AcrPull role to the Function App's
# system-assigned identity and remove the registry credential flags below.
Write-Host "── Creating Function App..." -ForegroundColor Yellow
$AcrPassword = az acr credential show `
    --name $AcrName `
    --query "passwords[0].value" `
    --output tsv

# Create the app with the custom image (--image tells the CLI this is a container app,
# so --runtime is not required)
az functionapp create `
    --resource-group $ResourceGroup `
    --name $FunctionAppName `
    --storage-account $StorageName `
    --plan $PlanName `
    --functions-version 4 `
    --image $FullImage `
    --os-type Linux `
    --output none

# Set registry credentials separately (--docker-registry-server-* removed in newer CLI)
Write-Host "── Configuring registry credentials..." -ForegroundColor Yellow
az functionapp config container set `
    --resource-group $ResourceGroup `
    --name $FunctionAppName `
    --registry-server "https://${AcrLoginServer}" `
    --registry-username $AcrName `
    --registry-password $AcrPassword `
    --output none

# 8. Enable continuous deployment webhook from ACR
Write-Host "── Enabling ACR → Function App continuous deployment webhook..." -ForegroundColor Yellow
$CiCdUrl = az functionapp deployment container config `
    --resource-group $ResourceGroup `
    --name $FunctionAppName `
    --enable-cd true `
    --query CI_CD_URL `
    --output tsv

az acr webhook create `
    --registry $AcrName `
    --name "funcappwebhook" `
    --uri $CiCdUrl `
    --actions push `
    --output none

Write-Host ""
Write-Host "=== Deployment complete ===" -ForegroundColor Green
Write-Host "Function App URL : https://${FunctionAppName}.azurewebsites.net"
Write-Host "HTTP Trigger     : https://${FunctionAppName}.azurewebsites.net/api/http_trigger"
Write-Host ""
Write-Host "── GitHub Actions OIDC setup ──────────────────────────" -ForegroundColor Cyan
Write-Host "1. Add this ONE secret in GitHub (Settings > Secrets > Actions):"
Write-Host "     AZURE_CLIENT_ID = $UamiClientId" -ForegroundColor Green
Write-Host ""
Write-Host "2. Create the federated credential (replace <org>/<repo> with your GitHub repo):"
Write-Host "   az identity federated-credential create ``"
Write-Host "     --identity-name '$UamiName' ``"
Write-Host "     --resource-group '$ResourceGroup' ``"
Write-Host "     --name 'github-main' ``"
Write-Host "     --issuer 'https://token.actions.githubusercontent.com' ``"
Write-Host "     --subject 'repo:<org>/<repo>:ref:refs/heads/main' ``"
Write-Host "     --audiences 'api://AzureADTokenExchange'"
