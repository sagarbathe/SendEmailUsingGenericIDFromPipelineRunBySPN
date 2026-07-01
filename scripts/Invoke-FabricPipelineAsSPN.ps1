###############################################################################
#  DEMO: Service Principal (SPN) triggers a Fabric Data Pipeline
#        Pipeline sends email from a generic service mailbox via Logic App
#
#  Pre-requisites (see README.md for full setup guide):
#    - SPN created in Entra ID with Mail.Send permission (admin-consented)
#    - SPN added as Contributor on the Fabric workspace
#    - SPN added to security group that has Fabric API access
#    - Logic App deployed (logic-app/la-send-email-arm.json)
#    - Fabric pipeline created with a WebHook activity pointing to Logic App
#
#  Flow:
#    [1] SPN acquires Fabric API token  (OAuth2 client credentials)
#    [2] SPN calls Fabric REST API      (trigger pipeline)
#    [3] Pipeline calls Logic App       (WebHook activity + callBackUri)
#    [4] Logic App acquires Graph token (SPN client credentials)
#    [5] Logic App sends email          (Graph API, service mailbox)
###############################################################################

# ── Configuration — replace ALL <PLACEHOLDER> values before running ───────────
$TenantId       = "<YOUR_ENTRA_TENANT_ID>"       # e.g. xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
$ClientId       = "<SPN_APPLICATION_CLIENT_ID>"  # App Registration Client ID
$ClientSecret   = "<SPN_CLIENT_SECRET>"          # App Registration Secret (use Key Vault in prod)
$WorkspaceId    = "<FABRIC_WORKSPACE_ID>"        # Fabric workspace GUID
$PipelineId     = "<FABRIC_PIPELINE_ID>"         # Pipeline item GUID
$RecipientEmail = "<RECIPIENT_EMAIL_ADDRESS>"    # Who receives the demo email
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DEMO: SPN triggers a Fabric Pipeline that sends email" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""


# ── STEP 1: SPN acquires Fabric API token ─────────────────────────────────────
Write-Host "STEP 1  Authenticate as SPN (client credentials flow)" -ForegroundColor Yellow
Write-Host "        Tenant   : $TenantId"
Write-Host "        Client ID: $ClientId"
Write-Host "        Scope    : https://api.fabric.microsoft.com/.default"
Write-Host ""

$tokenResponse = Invoke-RestMethod `
    -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body (
        "grant_type=client_credentials" +
        "&client_id=$ClientId" +
        "&client_secret=$ClientSecret" +
        "&scope=https%3A%2F%2Fapi.fabric.microsoft.com%2F.default"
    )

Write-Host "        Token acquired!" -ForegroundColor Green
Write-Host "        token_type : $($tokenResponse.token_type)"
Write-Host "        expires_in : $($tokenResponse.expires_in) seconds"
Write-Host "        access_token (first 60 chars): $($tokenResponse.access_token.Substring(0,60))..."
Write-Host ""


# ── STEP 2: SPN calls Fabric REST API to trigger the pipeline ─────────────────
Write-Host "STEP 2  Trigger Fabric Pipeline as SPN" -ForegroundColor Yellow
Write-Host "        Workspace: $WorkspaceId"
Write-Host "        Pipeline : $PipelineId"
Write-Host "        Endpoint : POST /v1/workspaces/{ws}/items/{pipeline}/jobs/instances"
Write-Host ""

$spnHeaders = @{
    Authorization  = "Bearer $($tokenResponse.access_token)"
    "Content-Type" = "application/json"
}
$body = @{
    executionData = @{
        parameters = @{ RecipientEmail = $RecipientEmail }
    }
} | ConvertTo-Json -Depth 5

$triggerResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$PipelineId/jobs/instances?jobType=Pipeline" `
    -Headers $spnHeaders `
    -Body $body `
    -UseBasicParsing

$jobUrl = $triggerResponse.Headers['Location']
Write-Host "        HTTP $($triggerResponse.StatusCode) Accepted" -ForegroundColor Green
Write-Host "        Job URL: $jobUrl"
Write-Host ""


# ── STEP 3–5: Poll pipeline until complete ────────────────────────────────────
Write-Host "STEP 3-5  Pipeline running: Logic App -> Graph API -> Service Mailbox" -ForegroundColor Yellow
Write-Host "          Polling for completion..." -ForegroundColor Gray
Write-Host ""

$pollHeaders = @{ Authorization = "Bearer $($tokenResponse.access_token)" }
$elapsed = 0
do {
    Start-Sleep -Seconds 10
    $elapsed += 10
    $status = Invoke-RestMethod -Uri $jobUrl -Headers $pollHeaders
    Write-Host "          [$elapsed`s] Status: $($status.status)" -ForegroundColor Gray
} while ($status.status -in @("NotStarted","InProgress","Running") -and $elapsed -lt 300)

Write-Host ""
if ($status.status -eq "Completed") {
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  SUCCESS!  Email sent to $RecipientEmail" -ForegroundColor Green
    Write-Host "  Auth method : OAuth2 Client Credentials (no user login)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
} else {
    Write-Host "  Pipeline status: $($status.status)" -ForegroundColor Red
    if ($status.failureReason) { Write-Host "  Error: $($status.failureReason.message)" -ForegroundColor Red }
}
Write-Host ""