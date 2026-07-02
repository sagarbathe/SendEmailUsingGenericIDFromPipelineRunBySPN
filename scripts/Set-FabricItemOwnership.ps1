<#
.SYNOPSIS
    Transfers ownership of all Fabric items in a workspace to a Service Principal (SPN).

.DESCRIPTION
    After deploying Fabric items to a production workspace, run this script to ensure
    all items are owned by the SPN rather than individual developers. This prevents
    failures when team members leave or accounts change.

    The script enumerates all items via the Fabric REST API and calls takeOwnership
    for each, authenticated as the SPN.

.PARAMETER TenantId
    Azure AD tenant ID.

.PARAMETER ClientId
    SPN application (client) ID.

.PARAMETER ClientSecret
    SPN client secret.

.PARAMETER WorkspaceId
    Fabric workspace ID (GUID) — the production workspace.

.PARAMETER ExcludeTypes
    Item types to skip. Defaults to "Report" (reports inherit ownership from the
    semantic model and do not have an independent takeOwnership endpoint).

.EXAMPLE
    .\Set-FabricItemOwnership.ps1 `
        -TenantId     "<TENANT_ID>" `
        -ClientId     "<SPN_CLIENT_ID>" `
        -ClientSecret "<SPN_CLIENT_SECRET>" `
        -WorkspaceId  "<PROD_WORKSPACE_ID>"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $TenantId,
    [Parameter(Mandatory)] [string]   $ClientId,
    [Parameter(Mandatory)] [string]   $ClientSecret,
    [Parameter(Mandatory)] [string]   $WorkspaceId,
    [string[]] $ExcludeTypes = @("Report")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Step 1: Get SPN token ─────────────────────────────────────────────────────
Write-Host "`n[1] Acquiring SPN token..." -ForegroundColor Cyan
$tokenResponse = Invoke-RestMethod `
    -Uri    "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Method POST `
    -Body   @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://api.fabric.microsoft.com/.default"
    }
$headers = @{
    Authorization  = "Bearer $($tokenResponse.access_token)"
    "Content-Type" = "application/json"
}
Write-Host "   ✅ Token acquired" -ForegroundColor Green

# ── Step 2: Enumerate all items in the workspace ──────────────────────────────
Write-Host "`n[2] Enumerating items in workspace $WorkspaceId..." -ForegroundColor Cyan
$items = [System.Collections.Generic.List[object]]::new()
$url   = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"
do {
    $page   = Invoke-RestMethod -Uri $url -Method GET -Headers $headers
    $page.value | ForEach-Object { $items.Add($_) }
    $url    = $page.continuationUri
} while ($url)

Write-Host "   Found $($items.Count) items" -ForegroundColor Green

# ── Step 3: Transfer ownership to SPN ─────────────────────────────────────────
Write-Host "`n[3] Transferring ownership to SPN..." -ForegroundColor Cyan

$results = @{ Success = 0; Skipped = 0; Failed = 0; Errors = [System.Collections.Generic.List[string]]::new() }

foreach ($item in $items) {
    $label = "[$($item.type.PadRight(22))] $($item.displayName)"

    if ($item.type -in $ExcludeTypes) {
        Write-Host "   ⏭  SKIP    $label" -ForegroundColor DarkGray
        $results.Skipped++
        continue
    }

    try {
        Invoke-RestMethod `
            -Uri     "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$($item.id)/takeOwnership" `
            -Method  POST `
            -Headers $headers | Out-Null

        Write-Host "   ✅ OWNED   $label" -ForegroundColor Green
        $results.Success++
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Host "   ❌ FAILED  $label — $errMsg" -ForegroundColor Red
        $results.Errors.Add("$label : $errMsg")
        $results.Failed++
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n──────────────────────────────────────────" -ForegroundColor White
Write-Host " Ownership transfer complete" -ForegroundColor White
Write-Host " ✅ Success  : $($results.Success)" -ForegroundColor Green
Write-Host " ⏭  Skipped  : $($results.Skipped)" -ForegroundColor DarkGray
Write-Host " ❌ Failed   : $($results.Failed)" -ForegroundColor Red

if ($results.Errors.Count -gt 0) {
    Write-Host "`n Errors:" -ForegroundColor Red
    $results.Errors | ForEach-Object { Write-Host "   • $_" -ForegroundColor Red }
}
Write-Host "──────────────────────────────────────────`n" -ForegroundColor White

if ($results.Failed -gt 0) {
    exit 1
}