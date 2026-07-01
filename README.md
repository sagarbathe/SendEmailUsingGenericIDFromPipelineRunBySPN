# Send Email from Generic Service Mailbox via Fabric Pipeline triggered by SPN

> **A Microsoft Fabric demo: a Service Principal (SPN) triggers a Data Pipeline that sends email from a generic service mailbox — zero user credentials involved.**

---

## Architecture

```
Caller (SPN)
    │
    │  [1] OAuth2 client_credentials → Entra ID token endpoint
    │  [2] POST /v1/workspaces/{ws}/items/{pipeline}/jobs/instances
    ▼
Fabric Data Pipeline  ──  WebHook activity
    │
    │  [3] HTTP POST with callBackUri → Logic App HTTP trigger
    ▼
Azure Logic App  (la-fabric-send-email)
    │
    │  [4] POST token endpoint → Graph API token (SPN client credentials)
    │  [5] POST /users/{service-mailbox}/sendMail  (Graph API)
    │  [6] POST callBackUri → signals pipeline completion
    ▼
Email delivered from generic service mailbox
```

## Key components

| Component | Description |
|-----------|-------------|
| **SPN** | Entra ID App Registration with `Mail.Send` Graph permission (admin-consented); Contributor on Fabric workspace |
| **Generic service mailbox** | An M365 shared mailbox or licensed user with no human owner — used as the "from" address |
| **Fabric Pipeline** | Single WebHook activity that calls the Logic App and waits for callback |
| **Logic App** (`la-fabric-send-email`) | Consumption tier; gets Graph token via SPN client credentials, sends email, posts callback to pipeline |

---

## Prerequisites

1. **Entra ID App Registration** with:
   - A client secret
   - Graph API **application** permission: `Mail.Send` (admin-consented)
   - Member of the security group listed in Fabric tenant setting: *Service principals can use Fabric APIs*

2. **Generic service mailbox** — either:
   - A shared mailbox in Exchange Online (no license needed up to 50 GB), OR
   - An M365 licensed user account used as a service account

3. **Fabric workspace** with the SPN added as **Contributor**

4. **Azure Logic App** deployed from `logic-app/la-send-email-arm.json`

5. **Fabric Data Pipeline** with a **WebHook activity** pointing to the Logic App trigger URL

---

## Setup guide

### Step 1 — Create the SPN

```bash
# Create App Registration and Service Principal
az ad app create --display-name "FabricPipelineSPN"
az ad sp create --id <APP_ID>

# Create client secret (2-year expiry)
az ad app credential reset --id <APP_ID> --years 2

# Add Mail.Send as an application (not delegated) permission
az ad app permission add \
  --id <APP_ID> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions b633e1c5-b582-4048-a93e-9f11b44c7e96=Role

# Grant admin consent
az ad app permission admin-consent --id <APP_ID>
```

### Step 2 — Create the generic service mailbox

**Option A — Shared mailbox (no license required):**
```powershell
# Exchange Online PowerShell
New-Mailbox -Shared -Name "Fabric Pipeline Service" -Alias "fabric-svc-email"
```

**Option B — M365 licensed user account:**
```bash
az rest --method POST --uri "https://graph.microsoft.com/v1.0/users" \
  --body '{
    "accountEnabled": true,
    "displayName": "Fabric Pipeline Service",
    "mailNickname": "fabric-svc-email",
    "userPrincipalName": "fabric-svc-email@<YOUR_DOMAIN>",
    "passwordProfile": {"password": "<STRONG_PASSWORD>", "forceChangePasswordNextSignIn": false},
    "usageLocation": "US"
  }'
# Assign an Exchange Online license to provision the mailbox
```

### Step 3 — Add SPN to Fabric API access group

The SPN must be a member of the security group listed under:  
**Fabric Admin portal → Tenant settings → Developer settings → Service principals can use Fabric APIs**

```bash
az ad group member add --group <GROUP_OBJECT_ID> --member-id <SP_OBJECT_ID>
```

### Step 4 — Add SPN as Contributor on Fabric workspace

In Fabric portal: **Workspace → Manage access → Add SPN as Contributor**

Or via REST API:
```bash
curl -X POST "https://api.fabric.microsoft.com/v1/workspaces/<WS_ID>/roleAssignments" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"principal":{"id":"<SP_OBJECT_ID>","type":"ServicePrincipal"},"role":"Contributor"}'
```

### Step 5 — Deploy the Logic App

```bash
az deployment group create \
  --resource-group <YOUR_RG> \
  --template-file logic-app/la-send-email-arm.json \
  --parameters logicAppName="la-fabric-send-email" \
               tenantId="<TENANT_ID>" \
               clientId="<SPN_CLIENT_ID>" \
               clientSecret="<SPN_CLIENT_SECRET>" \
               serviceMailbox="<SERVICE_EMAIL_ADDRESS>"
```

> **Security tip:** Store `clientSecret` in **Azure Key Vault** and reference it via a managed identity — do not hardcode it.

### Step 6 — Create the Fabric pipeline

1. In the Fabric portal, create a **Data Pipeline** named `Send Email via SPN`
2. Add a **WebHook** activity:
   - **URL**: Logic App HTTP trigger callback URL  
     *(Azure portal → Logic App → Overview → copy the trigger URL)*
   - **Method**: POST
   - **Body**:
     ```json
     {
       "recipientEmail": "@{pipeline().parameters.RecipientEmail}",
       "subject": "[Fabric] Email from SPN Pipeline",
       "pipelineName": "@{pipeline().Pipeline}",
       "runId": "@{pipeline().RunId}"
     }
     ```
3. Add pipeline parameter `RecipientEmail` (type: string)

> **Note:** Use **WebHook** activity (not WebActivity). WebActivity may be blocked by network policy in some Fabric environments; WebHook activity uses a callback pattern and is not subject to the same restriction.

---

## Running the demo

### Option 1 — PowerShell (interactive demo)

Fill in the placeholders in `scripts/Invoke-FabricPipelineAsSPN.ps1` and run:

```powershell
.\scripts\Invoke-FabricPipelineAsSPN.ps1
```

The script shows every step visibly — ideal for live demos.

### Option 2 — curl (Linux / macOS / WSL)

```bash
# Step 1: get SPN token for Fabric API
TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=<CLIENT_ID>&client_secret=<CLIENT_SECRET>&scope=https://api.fabric.microsoft.com/.default" \
  | jq -r .access_token)

# Step 2: trigger pipeline as SPN
curl -X POST \
  "https://api.fabric.microsoft.com/v1/workspaces/<WS_ID>/items/<PIPELINE_ID>/jobs/instances?jobType=Pipeline" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"executionData":{"parameters":{"RecipientEmail":"you@company.com"}}}'
```

### Option 3 — Python

```python
import requests

TENANT_ID     = "<YOUR_TENANT_ID>"
CLIENT_ID     = "<SPN_CLIENT_ID>"
CLIENT_SECRET = "<SPN_CLIENT_SECRET>"
WORKSPACE_ID  = "<FABRIC_WORKSPACE_ID>"
PIPELINE_ID   = "<FABRIC_PIPELINE_ID>"

# Step 1: get SPN token for Fabric API
token_resp = requests.post(
    f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token",
    data={
        "grant_type": "client_credentials",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "scope": "https://api.fabric.microsoft.com/.default",
    }
)
access_token = token_resp.json()["access_token"]

# Step 2: trigger pipeline as SPN
resp = requests.post(
    f"https://api.fabric.microsoft.com/v1/workspaces/{WORKSPACE_ID}/items/{PIPELINE_ID}/jobs/instances?jobType=Pipeline",
    headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
    json={"executionData": {"parameters": {"RecipientEmail": "you@company.com"}}}
)
job_url = resp.headers["Location"]
print(f"Pipeline triggered: {job_url}")
```

### Option 4 — GitHub Actions (CI/CD automation)

```yaml
name: Trigger Fabric Pipeline

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  trigger-pipeline:
    runs-on: ubuntu-latest
    steps:
      - name: Get SPN token
        id: token
        run: |
          TOKEN=$(curl -s -X POST \
            "https://login.microsoftonline.com/${{ secrets.FABRIC_TENANT_ID }}/oauth2/v2.0/token" \
            -d "grant_type=client_credentials&client_id=${{ secrets.FABRIC_CLIENT_ID }}&client_secret=${{ secrets.FABRIC_CLIENT_SECRET }}&scope=https://api.fabric.microsoft.com/.default" \
            | jq -r .access_token)
          echo "::add-mask::$TOKEN"
          echo "token=$TOKEN" >> $GITHUB_OUTPUT

      - name: Trigger Fabric pipeline
        run: |
          curl -X POST \
            "https://api.fabric.microsoft.com/v1/workspaces/${{ secrets.FABRIC_WS_ID }}/items/${{ secrets.FABRIC_PIPELINE_ID }}/jobs/instances?jobType=Pipeline" \
            -H "Authorization: Bearer ${{ steps.token.outputs.token }}" \
            -H "Content-Type: application/json" \
            -d '{"executionData":{"parameters":{"RecipientEmail":"${{ vars.NOTIFY_EMAIL }}"}}}'
```

Store `FABRIC_TENANT_ID`, `FABRIC_CLIENT_ID`, `FABRIC_CLIENT_SECRET`, `FABRIC_WS_ID`, `FABRIC_PIPELINE_ID` as **GitHub repository secrets**.

---

## Real-world calling patterns

| Pattern | Trigger | Typical use case |
|---------|---------|-----------------|
| **GitHub Actions / Azure DevOps** | Code push, PR merge, schedule | Notify team after data deployment or ETL completion |
| **Azure Logic Apps / Power Automate** | Business event, approval, schedule | Confirmation emails on form submission, approval workflows |
| **Azure Data Factory** | ADF pipeline step | Orchestrate Fabric from an existing ADF pipeline and send alerts |
| **Azure Functions** | Timer, Service Bus, Event Hub | Event-driven notifications — anomaly detection, threshold breach |
| **Custom app** (Python / C# / Java / Node) | API call, message queue | Internal portal sends email after a long-running job finishes |
| **Task Scheduler / cron** | Scheduled time | Nightly reports, daily digest from on-premises systems |

> **Key point for demos:** The PowerShell script shows what happens under the hood. In production, the same two HTTP calls — *get token → POST to Fabric* — are made by whichever automation system the customer already has.

---

## Security best practices

- ✅ **Never hardcode** `client_secret` — use Azure Key Vault or CI/CD secrets
- ✅ **Restrict Mail.Send** to a specific mailbox using `ApplicationAccessPolicy` in Exchange Online (prevents the SPN from sending as any mailbox in the tenant)
- ✅ **Rotate client secrets** on a schedule (every 6–12 months)
- ✅ **Monitor** runs via Azure Monitor and the Fabric Monitoring Hub
- ✅ **Least privilege** — SPN as Contributor (not Admin) on the workspace

### Restrict Mail.Send to one mailbox (strongly recommended for production)

```powershell
# Exchange Online PowerShell
New-ApplicationAccessPolicy `
  -AppId "<SPN_CLIENT_ID>" `
  -PolicyScopeGroupId "fabric-svc-email@yourdomain.com" `
  -AccessRight RestrictAccess `
  -Description "Restrict SPN to service mailbox only"
```

---

## Repository structure

```
├── README.md
├── scripts/
│   └── Invoke-FabricPipelineAsSPN.ps1   # PowerShell demo script (fill placeholders)
└── logic-app/
    └── la-send-email-arm.json           # ARM template — deploy the Logic App
```