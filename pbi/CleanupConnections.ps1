<#
.SYNOPSIS
    Detects and optionally deletes broken or unused Power BI / Microsoft Fabric connections.
.DESCRIPTION
    1. Signs in with a Microsoft account (no Power BI / Microsoft Fabric admin role required).
    2. Lists the connections and flags them as:
         - No permission: you are not the owner of the connection (User, UserWithReshare...), so it is not checked.
         - Broken: the Power BI "Get Datasource Status" API returns an error.
         - Unused: no item in any of your workspaces uses it (Microsoft Fabric "List Item Connections" API).
    3. Shows the result (Connection name, Type, Status) in the terminal or exports it to Excel.
    4. Optionally deletes the Broken or Unused connections selected in a grid window (Microsoft Fabric "Delete Connection" API).
.NOTES
    Author: Javier Buendía Carrera
    - The connections of an item can only be read with write permission on it. The script warns about the items it could not check.
    - The status of virtual network gateway connections cannot be checked, so they are only evaluated by usage.
    - Gateway admins who are not owners of a connection see it as "No permission", even though they could delete it.
.EXAMPLE
    .\CleanupConnections.ps1
#>
#Requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Constants

$RequiredModules = 'Az.Accounts', 'ImportExcel'

$FabricResource = 'https://api.fabric.microsoft.com'
$PowerBIResource = 'https://analysis.windows.net/powerbi/api'
$FabricApi = "$FabricResource/v1"
$PowerBIApi = 'https://api.powerbi.com/v1.0/myorg'

$MaxParallelism = 10                        # Parallel API calls
$MaxRetries = 5                             # Retries when the API rate limit is reached (HTTP 429)
$DefaultRetrySeconds = 30                   # Wait between retries if the API does not send Retry-After

$ManageableRole = 'Owner'                   # Connection role (myRole) needed to manage and delete a connection
$ItemsNotInScope = 'Report', 'Dashboard'
$UncheckableConnectivityTypes = 'VirtualNetworkGateway', 'StreamingVirtualNetworkGateway'   # Not supported by the status API

$StatusBroken = 'Broken'
$StatusUnused = 'Unused'
$ReportColumns = 'Connection name', 'Type', 'Status'
$ExcelFileName = '{0:yyyyMMdd_HHmmss}_Connections_Report.xlsx' -f (Get-Date)

#endregion

#region Functions

function Install-Dependencies {
    foreach ($module in $RequiredModules) {
        if (-not (Get-Module $module -ListAvailable)) {
            Write-Host "Installing $module module..." -ForegroundColor Yellow
            Install-Module $module -Scope CurrentUser -Force
        }
    }
}

function Connect-Account {
    Update-AzConfig -EnableLoginByWam $false -LoginExperienceV2 Off -Scope Process -WarningAction SilentlyContinue | Out-Null
    $account = Connect-AzAccount -WarningAction SilentlyContinue
    Write-Host "Signed in as $($account.Context.Account.Id)" -ForegroundColor Green
}

function Get-AccessToken([string]$Resource) {
    $token = (Get-AzAccessToken -ResourceUrl $Resource -WarningAction SilentlyContinue).Token
    if ($token -is [securestring]) {
        $token = [System.Net.NetworkCredential]::new('', $token).Password
    }
    @{ Authorization = "Bearer $token" }
}

function Invoke-Api([object[]]$Requests, [hashtable]$Headers, [string]$Method = 'Get', [switch]$ThrowOnError) {
    if (-not $Requests) { return }
    $results = @($Requests | ForEach-Object -ThrottleLimit $MaxParallelism -Parallel {
        $uri = $_.Uri
        $response = while ($uri) {
            for ($attempt = 0; $attempt -le $using:MaxRetries; $attempt++) {
                $page = Invoke-RestMethod $uri -Method $using:Method -Headers $using:Headers -SkipHttpErrorCheck -StatusCodeVariable status -ResponseHeadersVariable headers
                
                if ($status -ne 429) { break }
                
                $retryAfter = "$($headers['Retry-After'])"
                $retryAt = $retryAfter -as [datetimeoffset]
                Start-Sleep -Seconds ($retryAfter -match '^\d+$' ? [int]$retryAfter
                    : $retryAt ? [math]::Max(1, ($retryAt - [datetimeoffset]::UtcNow).TotalSeconds)
                    : $using:DefaultRetrySeconds)
            }
            if ($status -ge 400) { break }
            $page.value
            $uri = $page.continuationUri
        }
        [pscustomobject]@{ Request = $_; Response = @($response); StatusCode = $status; Error = $status -ge 400 ? $page : $null }
    })
    $failed = $results | Where-Object StatusCode -GE 400 | Select-Object -First 1
    if ($ThrowOnError -and $failed) { throw "API error $($failed.StatusCode) on $($failed.Request.Uri): $($failed.Error | ConvertTo-Json -Compress)" }
    $results
}

function Get-UsedConnections([hashtable]$Headers) {
    $workspaces = (Invoke-Api @{ Uri = "$FabricApi/workspaces" } $Headers -ThrowOnError).Response
    $itemLists = @(Invoke-Api ($workspaces | ForEach-Object {
        @{ Uri = "$FabricApi/workspaces/$($_.id)/items"; Workspace = $_.displayName }
    }) $Headers)
    $itemConnections = @(Invoke-Api $(foreach ($list in $itemLists) {
        $list.Response | Where-Object type -NotIn $ItemsNotInScope | ForEach-Object {
            @{ Uri = "$FabricApi/workspaces/$($_.workspaceId)/items/$($_.id)/connections"; Workspace = $list.Request.Workspace }
        }
    }) $Headers)

    # Collect items and connections that could not be checked due to API errors or lack of permissions.
    $unchecked = @($itemLists + $itemConnections | Where-Object { $_.StatusCode -ge 400 -and $_.Error.errorCode -ne 'OperationNotSupportedForItem' })
    if ($unchecked) {
        $reasons = $unchecked | Group-Object { $_.StatusCode -in 403, 404 ? 'without write permission' : 'with API errors' } |
            ForEach-Object { "$($_.Count) $($_.Name)" }
        Write-Warning ("Could not check some items ($($reasons -join ', ')), so connections used only by them appear as Unused. " +
            "Workspaces: $(($unchecked.Request.Workspace | Sort-Object -Unique) -join ', ')")
    }
    $itemConnections.Response.id
}

function Get-BrokenConnections([object[]]$Connections, [hashtable]$Headers) {
    $statusChecks = Invoke-Api ($Connections | Where-Object connectivityType -NotIn $UncheckableConnectivityTypes | ForEach-Object {
        @{ Uri = "$PowerBIApi/gateways/$($_.gatewayId)/datasources/$($_.id)/status"; Id = $_.id }
    }) $Headers
    # 
    ($statusChecks | Where-Object StatusCode -EQ 400).Request.Id
}

function Get-ConnectionsReport([hashtable]$FabricHeader, [hashtable]$PowerBIHeader) {
    $connections = (Invoke-Api @{ Uri = "$FabricApi/connections" } $FabricHeader -ThrowOnError).Response
    $manageable = @($connections | Where-Object myRole -EQ $ManageableRole)
    Write-Host "Found $($connections.Count) connections ($($manageable.Count) owned by you). Checking usage and status..."
    if (-not $connections) { return }

    $brokenIds = [System.Collections.Generic.HashSet[string]]@(Get-BrokenConnections $manageable $PowerBIHeader)
    $usedIds = [System.Collections.Generic.HashSet[string]]@(if ($manageable) { Get-UsedConnections $FabricHeader })

    $report = foreach ($connection in $connections) {
        $status = if ($connection.myRole -ne $ManageableRole) { 'No permission' }
                  elseif ($brokenIds.Contains($connection.id)) { $StatusBroken }
                  elseif (-not $usedIds.Contains($connection.id)) { $StatusUnused }
        if (-not $status) { continue }

        [pscustomobject]@{
            'Id'              = $connection.id
            'Connection name' = $connection.displayName ? $connection.displayName : $connection.connectionDetails.path
            'Type'            = $connection.connectionDetails.type
            'Status'          = $status
        }
    }
    $report | Sort-Object Status, 'Connection name'
}

function Show-Report([object[]]$Report) {
    $table = $Report | Select-Object $ReportColumns
    $choice = $Host.UI.PromptForChoice('Output', "Found $($Report.Count) connections to review. Where do you want to see them?", @('&Terminal', '&Excel'), 0)

    if ($choice -eq 0) {
        $table | Format-Table @{ Expression = 'Connection name'; Width = 60 }, Type, Status -Wrap | Out-Host
    } else {
        $path = Join-Path (Get-Location) $ExcelFileName
        $table | Export-Excel -Path $path -TableName 'Connections' -AutoSize
        Write-Host "Table exported to $path" -ForegroundColor Green
    }
}

function Remove-Connections([object[]]$Report, [hashtable]$Headers) {
    $deletable = @($Report | Where-Object Status -NE 'No permission')
    if (-not $deletable) { return }
    $choice = $Host.UI.PromptForChoice('Delete', "Do you want to delete any of the $($deletable.Count) broken or unused connections?", @('&Yes', '&No'), 1)
    $selected = if ($choice -eq 0) {
        Write-Host 'Select the connections to delete in the grid window (Ctrl/Shift for multiple) and press OK.' -ForegroundColor Cyan
        $deletable | Out-GridView -Title 'Connections' -OutputMode Multiple
    }
    if (-not $selected) {
        Write-Host 'No connections were deleted.' -ForegroundColor Yellow
        return
    }

    $results = @(Invoke-Api ($selected | ForEach-Object {
        @{ Uri = "$FabricApi/connections/$($_.Id)"; Name = $_.'Connection name' }
    }) $Headers -Method Delete)
    foreach ($result in $results) {
        if ($result.StatusCode -lt 400) { Write-Host "Deleted: $($result.Request.Name)" -ForegroundColor Green }
        else { Write-Warning "Could not delete '$($result.Request.Name)': HTTP $($result.StatusCode) $($result.Error.message)" }
    }
    $failed = @($results | Where-Object StatusCode -GE 400).Count
    Write-Host "Deleted: $($results.Count - $failed). Errors: $failed." -ForegroundColor Cyan
}

#endregion

#region Main

Install-Dependencies
Connect-Account

$report = @(Get-ConnectionsReport (Get-AccessToken $FabricResource) (Get-AccessToken $PowerBIResource))
if (-not $report) {
    Write-Host 'No connections to review were found.' -ForegroundColor Green
    return
}

Show-Report $report
Remove-Connections $report (Get-AccessToken $FabricResource)

#endregion