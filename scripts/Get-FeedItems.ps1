<#
.SYNOPSIS
    Feed fetching and normalisation helpers for M365 Change Radar.
.DESCRIPTION
    Dot-source this file to get Get-FeedItems, which turns an RSS or Atom feed
    into normalised update objects. No authentication is used anywhere in this
    project - every source is a public feed - so nothing tenant-specific can
    ever reach the published site.
.EXAMPLE
    . ./scripts/Get-FeedItems.ps1
    Get-FeedItems -Source $source
#>

Set-StrictMode -Version Latest

# Category vocabularies. The Roadmap and Azure feeds emit unlabelled <category>
# elements, so classification is by known value rather than by position.
$script:RoadmapStatus = @('In development', 'Rolling out', 'Launched', 'Cancelled')
$script:RoadmapRelease = @('General Availability', 'Preview')
$script:RoadmapRing = @(
    'Targeted Release', 'Standard Release', 'Current Channel',
    'Monthly Enterprise Channel', 'Semi-Annual Enterprise Channel',
    'Semi-Annual Enterprise Channel (Preview)', 'Beta Channel'
)
$script:RoadmapPlatform = @(
    'Web', 'Desktop', 'Mac', 'iOS', 'Android', 'Mobile', 'Windows',
    'Windows Desktop', 'Developer', 'US Instances'
)
$script:CloudPattern = '^(Worldwide|GCC|GCC High|DoD|China|US Government|Gallatin|21Vianet)'

$script:AzureStatus = @('Launched', 'In preview', 'In development')
$script:AzureGeneric = @('Feature', 'Features', 'Services', 'Retirements', 'SDK and Tools', 'Open Source')

# Retirements are the change type an admin most needs to see coming, so the
# flag has to be trustworthy. Two patterns, because the evidence differs in
# strength:
#
#   Title  - a bare mention is enough. If "retirement" is in the headline, the
#            item is about a retirement.
#   Body   - a bare mention is NOT enough, and matching one is how a launch
#            announcement gets mis-flagged ("...support timelines for older
#            Windows Server versions approach retirement..."). The body must
#            carry a verb construction saying the thing itself is going away.
$script:RetirementTitlePattern = 'retire|retiring|retirement|deprecat|end of support|end-of-support|breaking change|sunset'

$script:RetirementPhrases = @(
    'will be retired', 'will retire', 'is being retired', 'are being retired'
    'has been retired', 'have been retired', 'is retiring', 'are retiring'
    'will be deprecated', 'is deprecated', 'are deprecated', 'deprecation of'
    'end of support for', 'reaches end of support', 'reach end of support'
    'will be removed', 'will no longer be supported', 'will no longer be available'
) -join '|'

# In prose, announcing a breaking change means something you rely on is going
# away. A module changelog uses [BREAKING CHANGE] as a routine per-bullet label
# on an otherwise ordinary release, so psgallery matches the phrases alone.
$script:RetirementBodyPattern = "$script:RetirementPhrases|breaking change"

# Tech Community returns HTTP 200 with a stub feed for a board slug that does
# not exist. This sentinel is the only way to tell a dead slug from an empty blog.
$script:DeadFeedSentinel = 'has been deleted or never existed'

function ConvertTo-PlainText {
    <#
    .SYNOPSIS
        Strips HTML from feed description content and collapses it to a summary.
    .PARAMETER Html
        Raw description or content text from the feed.
    .PARAMETER MaxLength
        Maximum characters to keep. 0 keeps everything.
    .EXAMPLE
        ConvertTo-PlainText -Html $item.description -MaxLength 400
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Html,

        [int]$MaxLength = 400
    )

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }

    # Keep paragraph and list breaks as spaces so words do not run together.
    $text = $Html -replace '<(br|/p|/div|/li|/h[1-6])[^>]*>', ' '
    $text = $text -replace '<[^>]+>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = ($text -replace '\s+', ' ').Trim()

    if ($MaxLength -gt 0 -and $text.Length -gt $MaxLength) {
        $cut = $text.Substring(0, $MaxLength)
        $lastSpace = $cut.LastIndexOf(' ')
        if ($lastSpace -gt ($MaxLength * 0.6)) { $cut = $cut.Substring(0, $lastSpace) }
        $text = $cut.TrimEnd(' ', ',', '.', ';') + '...'
    }

    return $text
}

function Get-CurrentVersionNotes {
    <#
    .SYNOPSIS
        Isolates the current version's entry from a PowerShell Gallery ReleaseNotes field.
    .DESCRIPTION
        Some modules (e.g. ExchangeOnlineManagement) concatenate every past
        release's notes under the current one, banded off by a "Previous
        Releases:" marker - without this, every historical item would carry
        its entire release history. Also strips separator lines and the
        boilerplate "full changelog" link some modules repeat on every version.
    .PARAMETER Text
        Raw ReleaseNotes field text.
    .EXAMPLE
        Get-CurrentVersionNotes -Text $properties.ReleaseNotes.InnerText
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $text = $Text -replace '(?is)-{5,}\s*Previous Releases:.*$', ''
    $text = $text -replace '(?i)what is new in this release:', ''
    $text = $text -replace '(?is)-?\s*The complete release notes can be found.*$', ''
    $text = $text -replace '-{5,}', ''

    return $text.Trim()
}

function Get-NodeText {
    <#
    .SYNOPSIS
        Reads an XML child as text whether it is a bare text node or an element with attributes.
    .DESCRIPTION
        PowerShell surfaces <guid isPermaLink="false">123</guid> as an XmlElement but
        <title>x</title> as a string, so every field read goes through this.
    .PARAMETER Node
        The property value read off the item.
    .EXAMPLE
        Get-NodeText -Node $item.guid
    #>
    [CmdletBinding()]
    param([AllowNull()]$Node)

    if ($null -eq $Node) { return '' }
    if ($Node -is [string]) { return $Node.Trim() }
    if ($Node -is [System.Xml.XmlElement]) { return $Node.InnerText.Trim() }
    if ($Node -is [array] -and $Node.Count -gt 0) { return (Get-NodeText -Node $Node[0]) }
    return ([string]$Node).Trim()
}

function Get-XmlField {
    <#
    .SYNOPSIS
        Reads a named child element as text, returning '' when it is absent.
    .DESCRIPTION
        Feeds differ in which optional elements they emit - the Graph changelog
        has no <link> at all - and Set-StrictMode turns a missing property into a
        terminating error, so every optional field read goes through this.
    .PARAMETER Node
        The item or entry element.
    .PARAMETER Name
        Child element name.
    .EXAMPLE
        Get-XmlField -Node $item -Name 'link'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Node.PSObject.Properties.Name -notcontains $Name) { return '' }
    return Get-NodeText -Node $Node.$Name
}

function ConvertTo-UtcString {
    <#
    .SYNOPSIS
        Parses any feed date format to a round-trip UTC string.
    .DESCRIPTION
        Handles RFC 1123 with a GMT suffix (Tech Community), RFC 1123 with a bare
        Z suffix (Roadmap, Azure) and ISO 8601 (Atom).
    .PARAMETER Value
        The raw date string.
    .EXAMPLE
        ConvertTo-UtcString -Value 'Wed, 16 Sep 2026 22:57:03 Z'
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
              [System.Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        $parsed = [datetimeoffset]::Parse($Value, [cultureinfo]::InvariantCulture, $styles)
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    catch {
        Write-Verbose "Unparseable date '$Value'"
        return $null
    }
}

function Get-StableId {
    <#
    .SYNOPSIS
        Builds a deterministic item id from source id and feed guid.
    .PARAMETER SourceId
        Source identifier from sources.json.
    .PARAMETER Guid
        The feed's own guid, id or link for the item.
    .EXAMPLE
        Get-StableId -SourceId 'roadmap' -Guid '571389'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceId,
        [Parameter(Mandatory)][string]$Guid
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$SourceId|$Guid")
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant().Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FeedXml {
    <#
    .SYNOPSIS
        Downloads a feed and returns it as an XmlDocument.
    .DESCRIPTION
        Strips the UTF-8 BOM that the releasecommunications feeds emit, which
        otherwise makes the [xml] cast throw.
    .PARAMETER Url
        Feed URL.
    .PARAMETER TimeoutSec
        Request timeout.
    .EXAMPLE
        Get-FeedXml -Url 'https://example.com/rss'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 60
    )

    $headers = @{ 'User-Agent' = 'M365-Change-Radar/1.0 (+https://github.com/RobinpZA/M365-Change-Radar)' }
    $response = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
    $content = $response.Content -replace '^﻿', ''

    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Empty response body from $Url"
    }

    return [xml]$content
}

function Resolve-RoadmapCategories {
    <#
    .SYNOPSIS
        Splits unlabelled Roadmap categories into status, product, clouds and platforms.
    .PARAMETER Category
        The raw category values for one item.
    .EXAMPLE
        Resolve-RoadmapCategories -Category @('Launched','Worldwide (Standard Multi-Tenant)','Microsoft Teams')
    #>
    [CmdletBinding()]
    param([string[]]$Category)

    $status = $null
    $products = [System.Collections.Generic.List[string]]::new()
    $tags = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $Category) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $value = $c.Trim()

        if ($script:RoadmapStatus -contains $value) { if (-not $status) { $status = $value }; continue }
        if ($script:RoadmapRelease -contains $value) { $tags.Add($value) | Out-Null; continue }
        if ($script:RoadmapRing -contains $value) { $tags.Add($value) | Out-Null; continue }
        if ($script:RoadmapPlatform -contains $value) { $tags.Add($value) | Out-Null; continue }
        if ($value -match $script:CloudPattern) { $tags.Add($value) | Out-Null; continue }

        $products.Add($value) | Out-Null
    }

    return [PSCustomObject]@{
        Status  = $status
        Product = if ($products.Count -gt 0) { $products[0] } else { 'Microsoft 365' }
        Tags    = $tags.ToArray()
    }
}

function Resolve-AzureCategories {
    <#
    .SYNOPSIS
        Splits unlabelled Azure Updates categories into status, service area and tags.
    .PARAMETER Category
        The raw category values for one item.
    .EXAMPLE
        Resolve-AzureCategories -Category @('Retirements','Compute')
    #>
    [CmdletBinding()]
    param([string[]]$Category)

    $status = $null
    $areas = [System.Collections.Generic.List[string]]::new()
    $tags = [System.Collections.Generic.List[string]]::new()

    foreach ($c in $Category) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $value = $c.Trim()

        if ($script:AzureStatus -contains $value) { if (-not $status) { $status = $value }; continue }
        if ($script:AzureGeneric -contains $value) { $tags.Add($value) | Out-Null; continue }

        $areas.Add($value) | Out-Null
    }

    return [PSCustomObject]@{
        Status  = $status
        Product = if ($areas.Count -gt 0) { "Azure - $($areas[0])" } else { 'Azure' }
        Tags    = $tags.ToArray()
    }
}

function Get-FeedItems {
    <#
    .SYNOPSIS
        Fetches one feed and returns normalised update objects.
    .DESCRIPTION
        Throws on transport failure, unparseable XML or a Tech Community stub
        feed (a board slug that no longer exists). The caller decides whether a
        single source failing should be fatal.
    .PARAMETER Source
        One entry from config/sources.json.
    .PARAMETER TimeoutSec
        Request timeout in seconds.
    .EXAMPLE
        Get-FeedItems -Source $source -TimeoutSec 45
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Source,
        [int]$TimeoutSec = 60
    )

    $doc = Get-FeedXml -Url $Source.url -TimeoutSec $TimeoutSec
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    if ($Source.type -eq 'atom') {
        $entries = @($doc.feed.entry)
        if ($entries.Count -eq 0) { throw 'Atom feed contains no entries' }

        foreach ($entry in $entries) {
            $guid = Get-XmlField -Node $entry -Name 'id'
            if (-not $guid) { continue }

            $link = ''
            if ($entry.PSObject.Properties.Name -contains 'link' -and $entry.link.href) {
                $link = [string]$entry.link.href
            }

            $title = Get-XmlField -Node $entry -Name 'title'
            $summary = ConvertTo-PlainText -Html (Get-XmlField -Node $entry -Name 'content')

            # Some repos publish nightly or prerelease tags far more often than
            # they ship; excludeTitlePattern keeps that noise out of the feed.
            if ($Source.PSObject.Properties.Name -contains 'excludeTitlePattern' -and
                $Source.excludeTitlePattern -and $title -match $Source.excludeTitlePattern) {
                continue
            }

            # Some repos wrap the version in boilerplate on every release
            # ("v7.6.6 Release of PowerShell"); stripping it leaves the bare tag
            # the name prepend below expects.
            if ($Source.PSObject.Properties.Name -contains 'stripTitlePattern' -and $Source.stripTitlePattern) {
                $title = ($title -replace $Source.stripTitlePattern, '').Trim()
            }

            $results.Add([PSCustomObject]@{
                id           = Get-StableId -SourceId $Source.id -Guid $guid
                source       = $Source.id
                sourceName   = $Source.name
                kind         = $Source.kind
                product      = $Source.product
                title        = if ($Source.kind -eq 'releases') { "$($Source.name) $title" } else { $title }
                summary      = $summary
                link         = $link
                published    = ConvertTo-UtcString -Value (Get-XmlField -Node $entry -Name 'updated')
                status       = $null
                targetDate   = $null
                isRetirement = ($title -match $script:RetirementTitlePattern)
                tags         = @()
            }) | Out-Null
        }

        return $results
    }

    if ($Source.type -eq 'psgallery') {
        # PowerShell Gallery's OData feed has one <entry> per published version,
        # not per release note - the version lives in the entry id URL and the
        # real per-version publish date is <m:properties><d:Published>, since the
        # top-level <updated> element is unreliable (identical across versions).
        $entries = @($doc.feed.entry)
        if ($entries.Count -eq 0) { throw 'PowerShell Gallery feed contains no entries' }

        foreach ($entry in $entries) {
            $guid = Get-XmlField -Node $entry -Name 'id'
            if (-not $guid) { continue }

            $properties = $entry.properties
            $version = Get-XmlField -Node $properties -Name 'Version'
            if (-not $version) { continue }

            if ($Source.PSObject.Properties.Name -contains 'excludeTitlePattern' -and
                $Source.excludeTitlePattern -and $version -match $Source.excludeTitlePattern) {
                continue
            }

            $title = "$($Source.name) $version"
            $notes = Get-CurrentVersionNotes -Text (Get-XmlField -Node $properties -Name 'ReleaseNotes')

            # No title check - the title here is one this function built, so it
            # can only ever be "<module> <version>". No opening-paragraph window
            # either: a changelog is a list of discrete claims about this one
            # release, so a going-away bullet counts wherever it sits.
            $isRetirement = $notes -match $script:RetirementPhrases

            # Shipping a breaking change is worth surfacing, but it is a property
            # of a normal release, not a retirement, so it rides as a tag.
            $tags = @()
            if ($notes -match 'breaking change') { $tags = @('Breaking change') }

            $results.Add([PSCustomObject]@{
                id           = Get-StableId -SourceId $Source.id -Guid $guid
                source       = $Source.id
                sourceName   = $Source.name
                kind         = $Source.kind
                product      = $Source.product
                title        = $title
                summary      = ConvertTo-PlainText -Html $notes
                link         = "https://www.powershellgallery.com/packages/$($Source.packageId)/$version"
                published    = ConvertTo-UtcString -Value (Get-XmlField -Node $properties -Name 'Published')
                status       = $null
                targetDate   = $null
                isRetirement = $isRetirement
                tags         = $tags
            }) | Out-Null
        }

        return $results
    }

    # RSS
    $channelDescription = Get-XmlField -Node $doc.rss.channel -Name 'description'
    if ($channelDescription -match $script:DeadFeedSentinel) {
        throw "Feed returned the 'deleted or never existed' stub - the board slug in the URL is no longer valid"
    }

    if ($doc.rss.channel.PSObject.Properties.Name -notcontains 'item') {
        throw 'RSS feed contains no items'
    }

    $items = @($doc.rss.channel.item)
    foreach ($item in $items) {
        $title = Get-XmlField -Node $item -Name 'title'
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        $guid = Get-XmlField -Node $item -Name 'guid'
        if (-not $guid) { $guid = Get-XmlField -Node $item -Name 'link' }
        if (-not $guid) { continue }

        $rawDescription = Get-XmlField -Node $item -Name 'description'
        $categories = @()
        if ($item.PSObject.Properties.Name -contains 'category') {
            $categories = @($item.category | ForEach-Object { Get-NodeText -Node $_ })
        }

        $status = $null
        $product = $Source.product
        $tags = @()
        $targetDate = $null

        switch ($Source.kind) {
            'roadmap' {
                $resolved = Resolve-RoadmapCategories -Category $categories
                $status = $resolved.Status
                $product = $resolved.Product
                $tags = $resolved.Tags
                # Roadmap descriptions end with e.g. "GA date: October CY2026".
                if ($rawDescription -match '(?:GA|Preview)\s+date:\s*([^<\r\n]+)') {
                    $targetDate = $Matches[1].Trim()
                }
            }
            'azure' {
                $resolved = Resolve-AzureCategories -Category $categories
                $status = $resolved.Status
                $product = $resolved.Product
                $tags = $resolved.Tags
            }
            'graph-changelog' {
                # Items are workload-grouped; category carries the API version.
                $tags = $categories | Where-Object { $_ -in @('v1.0', 'beta') }
                $title = "Graph $title"
            }
            default {
                $tags = $categories
            }
        }

        $link = Get-XmlField -Node $item -Name 'link'
        if (-not $link -and $Source.PSObject.Properties.Name -contains 'fallbackLink') {
            $link = $Source.fallbackLink
        }

        # Only the opening of the body counts. A post that IS a retirement notice
        # says so in its first breath; a monthly roundup that happens to mention
        # one several paragraphs down is not a retirement and should not be
        # tagged as one.
        $bodyOpening = $rawDescription
        if ($bodyOpening.Length -gt 600) { $bodyOpening = $bodyOpening.Substring(0, 600) }

        $isRetirement = ($title -match $script:RetirementTitlePattern) -or
                        ($categories -contains 'Retirements') -or
                        ($bodyOpening -match $script:RetirementBodyPattern)

        $results.Add([PSCustomObject]@{
            id           = Get-StableId -SourceId $Source.id -Guid $guid
            source       = $Source.id
            sourceName   = $Source.name
            kind         = $Source.kind
            product      = $product
            title        = $title
            summary      = ConvertTo-PlainText -Html $rawDescription
            link         = $link
            published    = ConvertTo-UtcString -Value (Get-XmlField -Node $item -Name 'pubDate')
            status       = $status
            targetDate   = $targetDate
            isRetirement = [bool]$isRetirement
            tags         = @($tags)
        }) | Out-Null
    }

    return $results
}
