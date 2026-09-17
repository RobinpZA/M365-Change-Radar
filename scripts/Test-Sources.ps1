<#
.SYNOPSIS
    Health check for every feed in config/sources.json.
.DESCRIPTION
    Fetches each enabled source and reports item counts and the newest item.
    Exits non-zero if any source fails, so it can gate CI. Feed URLs rot - the
    Tech Community Aurora migration broke every legacy RSS URL at once - so run
    this whenever the site looks stale.
.PARAMETER ConfigPath
    Path to sources.json. Defaults to config/sources.json next to the repo root.
.PARAMETER Id
    Test only the named source ids.
.EXAMPLE
    pwsh ./scripts/Test-Sources.ps1
.EXAMPLE
    pwsh ./scripts/Test-Sources.ps1 -Id blog-entra, roadmap
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string[]]$Id
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Get-FeedItems.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $root 'config/sources.json' }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$sources = $config.sources | Where-Object { $_.enabled }
if ($Id) { $sources = $sources | Where-Object { $_.id -in $Id } }

Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║   M365 Change Radar - Source Health Check    ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

$failures = [System.Collections.Generic.List[string]]::new()
$index = 0

foreach ($source in $sources) {
    $index++
    $label = '[{0}/{1}] {2}' -f $index, @($sources).Count, $source.id
    try {
        $items = Get-FeedItems -Source $source
        if (@($items).Count -eq 0) {
            # The feed responded with entries but excludeTitlePattern dropped
            # them all - healthy, just currently contributing nothing.
            Write-Host ("{0,-28} reachable, all entries excluded by filter" -f $label) -ForegroundColor Yellow
            continue
        }

        $newest = $items | Sort-Object published -Descending | Select-Object -First 1
        $age = if ($newest.published) { ((Get-Date).ToUniversalTime() - [datetime]$newest.published).Days } else { -1 }
        $colour = if ($age -gt 120 -or $age -lt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("{0,-28} {1,5} items  newest {2,4}d  {3}" -f $label, @($items).Count, $age, $newest.title) -ForegroundColor $colour
    }
    catch {
        $failures.Add($source.id) | Out-Null
        Write-Host ("{0,-28} FAILED: {1}" -f $label, $_.Exception.Message) -ForegroundColor Red
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "  $($failures.Count) source(s) failing: $($failures -join ', ')" -ForegroundColor Red
    exit 1
}

Write-Host "  All $(@($sources).Count) sources healthy." -ForegroundColor Green
exit 0
