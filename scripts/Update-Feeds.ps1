<#
.SYNOPSIS
    Fetches every configured feed and rebuilds docs/data/updates.json.
.DESCRIPTION
    Merges this run against the previous output so that firstSeen and
    statusHistory survive - that history is what turns a pile of RSS into a
    "what actually changed since I last looked" view.

    A source that fails is non-fatal: its previously collected items are kept and
    the failure is recorded in meta.json and surfaced as a GitHub Actions
    warning annotation. A broken feed must never blank the site.

    Every source is public. Nothing here authenticates, so no tenant data can
    reach the published site.
.PARAMETER ConfigPath
    Path to sources.json.
.PARAMETER OutputPath
    Directory for updates.json and meta.json.
.PARAMETER Id
    Limit the run to the named source ids (for local testing).
.EXAMPLE
    pwsh ./scripts/Update-Feeds.ps1
.EXAMPLE
    pwsh ./scripts/Update-Feeds.ps1 -Id roadmap
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputPath,
    [string[]]$Id
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-FeedItems.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config/sources.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $root 'docs/data' }

$updatesFile = Join-Path $OutputPath 'updates.json'
$metaFile = Join-Path $OutputPath 'meta.json'
$runTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$inActions = [bool]$env:GITHUB_ACTIONS

function Write-Annotation {
    <#
    .SYNOPSIS
        Writes a warning locally and as a GitHub Actions annotation when running in CI.
    .PARAMETER Message
        Warning text.
    .EXAMPLE
        Write-Annotation -Message 'feed blog-entra failed'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    if ($inActions) { Write-Host "::warning::$Message" }
    Write-Host "  ! $Message" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║   M365 Change Radar - Feed Update  v1.0.0    ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$retentionMonths = if ($config.PSObject.Properties.Name -contains 'retentionMonths') { $config.retentionMonths } else { 18 }

$sources = @($config.sources | Where-Object { $_.enabled })
if ($Id) { $sources = @($sources | Where-Object { $_.id -in $Id }) }

# Previous run, keyed by id, so firstSeen and statusHistory carry forward.
$existing = @{}
if (Test-Path $updatesFile) {
    foreach ($item in (Get-Content $updatesFile -Raw | ConvertFrom-Json)) {
        $existing[$item.id] = $item
    }
    Write-Host "  Loaded $($existing.Count) items from previous run" -ForegroundColor DarkCyan
}
else {
    Write-Host '  No previous updates.json - this is a first run' -ForegroundColor DarkCyan
}

$previousMeta = $null
if (Test-Path $metaFile) { $previousMeta = Get-Content $metaFile -Raw | ConvertFrom-Json }

$merged = [System.Collections.Generic.Dictionary[string, PSCustomObject]]::new()
$sourceReports = [System.Collections.Generic.List[PSCustomObject]]::new()
$healthySources = [System.Collections.Generic.HashSet[string]]::new()
$newIds = [System.Collections.Generic.HashSet[string]]::new()
$statusChangeCount = 0
$index = 0

Write-Host ''
foreach ($source in $sources) {
    $index++
    $label = '[{0}/{1}] {2}' -f $index, $sources.Count, $source.id

    try {
        # An empty result here means every entry was excluded by
        # excludeTitlePattern, not that the feed is broken - Get-FeedItems throws
        # when the feed itself has no entries.
        $items = @(Get-FeedItems -Source $source)

        foreach ($item in $items) {
            if (-not $item.published) { $item.published = $runTime }

            $prior = $null
            if ($existing.ContainsKey($item.id)) { $prior = $existing[$item.id] }

            if ($prior) {
                $history = @($prior.statusHistory)
                $lastStatus = if ($history.Count -gt 0) { $history[-1].status } else { $null }

                if ($item.status -and $item.status -ne $lastStatus) {
                    $history += [PSCustomObject]@{ status = $item.status; seen = $runTime }
                    $statusChangeCount++
                }

                $item | Add-Member -NotePropertyName firstSeen -NotePropertyValue $prior.firstSeen
                $item | Add-Member -NotePropertyName statusHistory -NotePropertyValue $history
            }
            else {
                $history = @()
                if ($item.status) { $history = @([PSCustomObject]@{ status = $item.status; seen = $runTime }) }

                $item | Add-Member -NotePropertyName firstSeen -NotePropertyValue $runTime
                $item | Add-Member -NotePropertyName statusHistory -NotePropertyValue $history
                $newIds.Add($item.id) | Out-Null
            }

            $merged[$item.id] = $item
        }

        $healthySources.Add($source.id) | Out-Null
        $lastSuccess = $runTime
        $sourceReports.Add([PSCustomObject]@{
            id          = $source.id
            name        = $source.name
            kind        = $source.kind
            status      = 'ok'
            itemCount   = $items.Count
            lastSuccess = $lastSuccess
            error       = $null
        }) | Out-Null

        Write-Host ("  {0,-30} {1,5} items" -f $label, $items.Count) -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message
        Write-Annotation -Message "$($source.id) ($($source.url)): $message"

        $lastSuccess = $null
        if ($previousMeta) {
            $prevSource = $previousMeta.sources | Where-Object { $_.id -eq $source.id } | Select-Object -First 1
            if ($prevSource) { $lastSuccess = $prevSource.lastSuccess }
        }

        $sourceReports.Add([PSCustomObject]@{
            id          = $source.id
            name        = $source.name
            kind        = $source.kind
            status      = 'failed'
            itemCount   = 0
            lastSuccess = $lastSuccess
            error       = $message
        }) | Out-Null
    }
}

if ($healthySources.Count -eq 0) {
    Write-Host ''
    Write-Host '  Every source failed - leaving the existing data untouched.' -ForegroundColor Red
    exit 1
}

# Carry forward items whose source was not fetched this run (failed, or excluded
# by -Id) and items a blog has already rolled off its 20-item window.
foreach ($key in $existing.Keys) {
    if (-not $merged.ContainsKey($key)) { $merged[$key] = $existing[$key] }
}

$cutoff = (Get-Date).ToUniversalTime().AddMonths(-$retentionMonths)
$all = @($merged.Values |
    Where-Object { $_.published -and ([datetime]$_.published) -ge $cutoff } |
    Sort-Object -Property @{ Expression = { [datetime]$_.published } } -Descending)

$products = @($all.product | Where-Object { $_ } | Sort-Object -Unique)
$statuses = @($all.status | Where-Object { $_ } | Sort-Object -Unique)

# Count only new items that survived the retention prune, so the figure matches
# what the site actually shows.
$newCount = @($all | Where-Object { $newIds.Contains($_.id) }).Count

# The seed run stamps every item with the same firstSeen, which would otherwise
# make the whole backlog look "new" for the first few days. The site treats this
# baseline timestamp as "always been there".
$baselineFirstSeen = @($all.firstSeen | Sort-Object) | Select-Object -First 1

$meta = [PSCustomObject]@{
    generator         = 'M365-Change-Radar'
    lastRun           = $runTime
    baselineFirstSeen = $baselineFirstSeen
    itemCount         = $all.Count
    newThisRun        = $newCount
    statusChanges     = $statusChangeCount
    retentionMonths   = $retentionMonths
    products          = $products
    statuses          = $statuses
    sources           = $sourceReports
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$all | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $updatesFile -Encoding utf8NoBOM
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $metaFile -Encoding utf8NoBOM

$sizeKb = [math]::Round((Get-Item $updatesFile).Length / 1KB)
$failed = @($sourceReports | Where-Object { $_.status -eq 'failed' })

Write-Host ''
Write-Host "  Items:          $($all.Count) (pruned to last $retentionMonths months)" -ForegroundColor Cyan
Write-Host "  New this run:   $newCount" -ForegroundColor Cyan
Write-Host "  Status changes: $statusChangeCount" -ForegroundColor Cyan
Write-Host "  Sources:        $($healthySources.Count) ok, $($failed.Count) failed" -ForegroundColor Cyan
Write-Host "  Written:        $updatesFile ($sizeKb KB)" -ForegroundColor Green
Write-Host ''
