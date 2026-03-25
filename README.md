# FunctionDeployTest

A **containerised Python Azure Function App** (HTTP trigger) with:

- 🐳 **Dockerfile** – builds a slim Azure Functions Python image
- ☁️ **Azure CLI deploy script** – provisions ACR (Basic) + Function Premium (EP1) at minimum cost
- 🚀 **GitHub Actions workflow** – builds & pushes the container to ACR, then deploys to Azure

---

## Repository layout

```
.
├── Dockerfile                        # Container image for the function app
├── host.json                         # Azure Functions host configuration
├── requirements.txt                  # Python dependencies
├── http_trigger/
│   ├── __init__.py                   # HTTP-triggered function
│   └── function.json                 # Function bindings
├── infra/
│   └── deploy.sh                     # Azure CLI provisioning script
└── .github/
    └── workflows/
        └── deploy.yml                # GitHub Actions CI/CD pipeline
```

---

## 1 · Provision Azure resources

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) ≥ 2.55
- An Azure subscription
- `az login` completed

### Run the script

```bash
chmod +x infra/deploy.sh

# Optional overrides (shown with their defaults)
export RESOURCE_GROUP="rg-funcapp-container"
export LOCATION="eastus"
# ACR_NAME and STORAGE_NAME are randomised by default to ensure uniqueness

./infra/deploy.sh
```

The script prints the values you need to add as **GitHub Actions secrets** (see step 3).

#### Resources created (minimum cost)

| Resource | SKU / tier | Why minimum cost |
|---|---|---|
| Resource Group | – | Free |
| Azure Container Registry | **Basic** | Cheapest paid tier (~$0.17/day) |
| Storage Account | **Standard LRS** | Cheapest redundancy |
| App Service Plan | **Elastic Premium EP1** | Smallest premium SKU; scales to 0 when idle |
| Function App | Linux container | Billed only for execution time on EP1 |

---

## 2 · Local development

```bash
# Install dependencies
pip install -r requirements.txt

# Run locally (requires Azure Functions Core Tools v4)
func start
```

Test the function:

```bash
curl "http://localhost:7071/api/http_trigger?name=World"
```

---

## 3 · GitHub Actions CI/CD

### Required secrets

Add these in **Settings → Secrets and variables → Actions**:

| Secret name | How to obtain |
|---|---|
| `AZURE_CREDENTIALS` | `az ad sp create-for-rbac --name "github-actions-sp" --role contributor --scopes /subscriptions/<sub>/resourceGroups/<rg> --sdk-auth` |
| `ACR_LOGIN_SERVER` | Printed by `deploy.sh`, e.g. `acrfuncapp12345.azurecr.io` |
| `ACR_USERNAME` | Same as your ACR name |
| `ACR_PASSWORD` | Printed by `deploy.sh` or via `az acr credential show --name <acr-name>` |
| `AZURE_FUNCTION_APP_NAME` | Printed by `deploy.sh` |
| `AZURE_RESOURCE_GROUP` | Value of `$RESOURCE_GROUP` used in `deploy.sh` |

### Workflow overview

```
push to main
    │
    ▼
build-and-push job
    • docker/login-action  → logs in to ACR
    • docker/build-push-action → builds image, pushes :latest + :<short-sha>
    │
    ▼
deploy job
    • azure/login          → authenticates to Azure
    • azure/cli            → az functionapp config container set (new image)
    • azure/cli            → az functionapp show (verify state)
```

The pipeline runs automatically on every push to `main`, or can be triggered manually from the **Actions** tab.
