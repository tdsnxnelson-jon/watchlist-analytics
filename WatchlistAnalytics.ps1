[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [Alias('Config')]
    [string]$ConfigPath = $(if (Test-Path (Join-Path $PSScriptRoot 'cb-creds.json')) {
            Join-Path $PSScriptRoot 'cb-creds.json'
        } else {
            Join-Path $PSScriptRoot 'WatchlistAnalytics.config.json'
        }),

    [Parameter(Mandatory = $false)]
    [datetime]$StartDate,

    [Parameter(Mandatory = $false)]
    [datetime]$EndDate,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Default
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $Default
    }
    return $property.Value
}

function Resolve-PathTemplate {
    param([Parameter(Mandatory = $true)][string]$PathTemplate)

    return $PathTemplate.Replace('{orgKey}', [string]$script:Config.OrgKey)
}

function Invoke-CbcRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)]$Body
    )

    $uri = '{0}{1}' -f $script:Config.BaseUrl.TrimEnd('/'), (Resolve-PathTemplate -PathTemplate $Path)
    $headers = @{
        'X-Auth-Token' = '{0}/{1}' -f $script:ApiSecret, $script:Config.ApiId
        'Accept' = 'application/json'
        'User-Agent' = 'WatchlistAnalytics/1.0'
    }

    $requestParameters = @{
        Uri = $uri
        Method = $Method
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $requestParameters.ContentType = 'application/json'
        $requestParameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    Write-Verbose ('{0} {1}' -f $Method, $uri)
    try {
        return Invoke-RestMethod @requestParameters
    } catch {
        $statusCode = $null
        $response = $null
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty) { $response = $responseProperty.Value }
        if ($null -ne $response) {
            $statusCode = [int]$response.StatusCode
        }
        if ($statusCode -eq 401 -or $_.Exception.Message -match 'UNAUTHENTICATED') {
            throw "Carbon Black rejected the API credentials for '$uri'. Verify that '$($script:Config.ApiSecretEnvironmentVariable)' is set in this terminal, that its secret matches ApiId '$($script:Config.ApiId)', and that BaseUrl '$($script:Config.BaseUrl)' is the tenant's region."
        }
        if ($null -ne $statusCode) {
            $detail = if ($null -ne $_.ErrorDetails) { $_.ErrorDetails.Message } else { '' }
            if ([string]::IsNullOrWhiteSpace($detail) -and $null -ne $response.PSObject.Methods['GetResponseStream']) {
                $reader = $null
                try {
                    $stream = $response.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        $detail = $reader.ReadToEnd()
                    }
                } catch {
                    $detail = ''
                } finally {
                    if ($null -ne $reader) { $reader.Dispose() }
                }
            }
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'No response body was available.' }
            if (-not [string]::IsNullOrEmpty($script:ApiSecret)) {
                $detail = $detail.Replace($script:ApiSecret, '[REDACTED]')
            }
            throw "Carbon Black request failed (HTTP $statusCode): $Method $uri. Response: $detail"
        }
        throw
    }
}

function Get-ResponseItems {
    param([Parameter(Mandatory = $true)]$Response)

    foreach ($propertyName in @('results', 'items', 'data', 'records', 'alerts', 'watchlists', 'reports')) {
        $property = $Response.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            if ($property.Value -is [System.Collections.IEnumerable] -and $property.Value -isnot [string]) {
                return @($property.Value)
            }
        }
    }

    if ($Response -is [System.Collections.IEnumerable] -and $Response -isnot [string]) {
        return @($Response)
    }
    return @($Response)
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)]$Default = $null
    )

    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current -or [string]::IsNullOrWhiteSpace([string]$current)) { return $Default }
    return $current
}

function Format-FieldValue {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [System.Array]) { return ($Value -join ', ') }
    return [string]$Value
}

function Resolve-AlertDateWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][datetime]$StartDate,
        [Parameter(Mandatory = $true)][datetime]$EndDate,
        [datetime]$Now = [datetime]::UtcNow
    )

    $start = $StartDate.ToUniversalTime()
    $end = $EndDate.ToUniversalTime()
    $nowUtc = $Now.ToUniversalTime()
    if ($end -le $start) { throw 'EndDate must be later than StartDate.' }
    if ($start -ge $nowUtc) { throw 'StartDate must be earlier than now.' }

    $earliestStart = $nowUtc.AddDays(-180).AddMinutes(5)
    if ($start -lt $earliestStart) { $start = $earliestStart }
    if ($end -le $start -or $end -gt $nowUtc) { $end = $nowUtc }
    if ($start -ne $StartDate.ToUniversalTime() -or $end -ne $EndDate.ToUniversalTime()) {
        Write-Information -Tags 'INFO' -InformationAction Continue -MessageData (
            'INFO: Adjusted requested UTC window [{0}, {1}] to [{2}, {3}] for 180-day alert retention (five-minute cutoff buffer).' -f
            $StartDate.ToUniversalTime().ToString('o'), $EndDate.ToUniversalTime().ToString('o'),
            $start.ToString('o'), $end.ToString('o'))
    }
    return [pscustomobject]@{ StartDate = $start; EndDate = $end }
}

function New-AnalyticsFilter {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartDate,
        [Parameter(Mandatory = $true)][datetime]$EndDate,
        [switch]$WatchlistOnly
    )

    if ($EndDate -le $StartDate) { throw 'EndDate must be later than StartDate.' }
    $template = Get-PropertyValue -Object $script:Config -Path 'AlertSearch.BodyTemplate' -Default ([pscustomobject]@{})
    $filter = [ordered]@{}
    foreach ($name in @('query', 'criteria', 'exclusions')) {
        $property = $template.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $filter[$name] = $property.Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        }
    }
    $filter.time_range = [ordered]@{
        start = $StartDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fff'Z'")
        end = $EndDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fff'Z'")
    }
    if ($WatchlistOnly) {
        if (-not $filter.Contains('criteria')) { $filter.criteria = [pscustomobject]@{} }
        $typeProperty = $filter.criteria.PSObject.Properties['type']
        if ($null -ne $typeProperty -and @($typeProperty.Value).Count -gt 0 -and @($typeProperty.Value) -notcontains 'WATCHLIST') {
            throw 'AlertSearch.BodyTemplate.criteria.type must include WATCHLIST for watchlist analytics.'
        }
        $filter.criteria | Add-Member -NotePropertyName type -NotePropertyValue @('WATCHLIST') -Force
    }
    return $filter
}

function Get-AlertAggregations {
    param(
        [Parameter(Mandatory = $true)][datetime]$StartDate,
        [Parameter(Mandatory = $true)][datetime]$EndDate,
        [ValidateRange(1, 2147483647)][int]$FacetRows = 50
    )

    if ($FacetRows -gt 50) {
        Write-AnalyticsStatus ("Analytics.FacetRows adjusted from {0} to 50 to match the Alerts API facet limit." -f $FacetRows)
        $FacetRows = 50
    }
    $searchPath = [string](Get-PropertyValue -Object $script:Config -Path 'AlertSearch.Path' -Default '/api/alerts/v7/orgs/{orgKey}/alerts/_search')
    if (-not $searchPath.EndsWith('/_search')) { throw 'AlertSearch.Path must end with /_search.' }
    $basePath = $searchPath.Substring(0, $searchPath.Length - '/_search'.Length)
    $raw = [System.Collections.Generic.List[object]]::new()
    $counts = @{}
    foreach ($scope in @('All', 'Watchlist')) {
        $body = New-AnalyticsFilter -StartDate $StartDate -EndDate $EndDate -WatchlistOnly:($scope -eq 'Watchlist')
        $body.start = 1
        $body.rows = 0
        Write-AnalyticsStatus ("Counting {0} alerts across the requested window; no alert records will be downloaded." -f $scope)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-CbcRequest -Method POST -Path $searchPath -Body $body
        $countValue = Get-PropertyValue -Object $response -Path 'num_found'
        $count = [int64]0
        if ($null -eq $countValue -or -not [int64]::TryParse([string]$countValue, [ref]$count) -or $count -lt 0) {
            throw "The $scope count response did not contain a valid num_found."
        }
        $counts[$scope] = $count
        $raw.Add([pscustomobject]@{ Operation = "${scope}Count"; Method = 'POST'; Path = $searchPath; Request = $body; Response = $response })
        Write-AnalyticsStatus ("{0} alerts: {1}; elapsed {2}." -f $scope, $count, $timer.Elapsed.ToString('c'))
    }
    $facets = $null
    $histogram = $null
    if ($counts.Watchlist -gt 0) {
        $body = New-AnalyticsFilter -StartDate $StartDate -EndDate $EndDate -WatchlistOnly
        $body.terms = @{ rows = $FacetRows; fields = @('report_name', 'device_name', 'process_username') }
        $body.filter_values = $true
        Write-AnalyticsStatus ("Fetching top {0} report names, device names and process users; waiting for aggregation response." -f $FacetRows)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $facets = Invoke-CbcRequest -Method POST -Path "$basePath/_facet" -Body $body
        $raw.Add([pscustomobject]@{ Operation = 'WatchlistFacets'; Method = 'POST'; Path = "$basePath/_facet"; Request = $body; Response = $facets })
        Write-AnalyticsStatus ("Facet request complete; elapsed {0}." -f $timer.Elapsed.ToString('c'))
        $body = New-AnalyticsFilter -StartDate $StartDate -EndDate $EndDate -WatchlistOnly
        $body.field = 'BACKEND_TIMESTAMP'
        $body.bucket_size = '+1DAY'
        $body.min_count = 0
        Write-AnalyticsStatus 'Fetching daily watchlist alert totals; waiting for histogram response.'
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $histogram = Invoke-CbcRequest -Method POST -Path "$basePath/_histogram" -Body $body
        $raw.Add([pscustomobject]@{ Operation = 'WatchlistHistogram'; Method = 'POST'; Path = "$basePath/_histogram"; Request = $body; Response = $histogram })
        Write-AnalyticsStatus ("Histogram request complete; elapsed {0}." -f $timer.Elapsed.ToString('c'))
    }
    return [pscustomobject]@{
        TotalAlerts = $counts.All
        WatchlistAlerts = $counts.Watchlist
        FacetRows = $FacetRows
        Facets = $facets
        Histogram = $histogram
        Raw = $raw.ToArray()
    }
}

function Write-AnalyticsStatus {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Information -Tags 'INFO' -InformationAction Continue -MessageData (
        '[{0}] INFO: {1}' -f [datetime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'"), $Message)
}

function Get-FacetRanking {
    param(
        [Parameter(Mandatory = $true)]$Aggregations,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ($Aggregations.WatchlistAlerts -eq 0) {
        return [pscustomobject]@{ Field = $Field; Rows = @(); AtLimit = $false; Status = 'No watchlist alerts' }
    }
    $resultsProperty = $Aggregations.Facets.PSObject.Properties['results']
    if ($null -eq $resultsProperty) { throw 'Facet response is missing results.' }
    $matches = @($resultsProperty.Value | Where-Object { $_.field -eq $Field })
    if ($matches.Count -ne 1 -or $null -eq $matches[0].PSObject.Properties['values']) {
        throw "Facet response is missing values for '$Field'."
    }
    $rows = @(foreach ($value in $matches[0].values) {
        $count = [int64]0
        if (-not [int64]::TryParse([string]$value.total, [ref]$count) -or $count -lt 0) { throw "Invalid count in '$Field' facet." }
        [pscustomobject]@{
            Name = [string](Get-PropertyValue -Object $value -Path 'name' -Default ([string]$value.id))
            Alerts = $count
            PercentOfWatchlistAlerts = [math]::Round(100.0 * $count / $Aggregations.WatchlistAlerts, 2)
            PercentOfAllAlerts = if ($Aggregations.TotalAlerts -gt 0) { [math]::Round(100.0 * $count / $Aggregations.TotalAlerts, 2) } else { $null }
        }
    })
    return [pscustomobject]@{
        Field = $Field
        Rows = @($rows | Sort-Object Alerts -Descending)
        AtLimit = ($rows.Count -ge $Aggregations.FacetRows)
        Status = 'Top returned values only; missing values and omitted terms are not zero counts'
    }
}

function ConvertFrom-ApiTimestamp {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Not provided by API' }
    $seconds = [int64]0
    if ([int64]::TryParse([string]$Value, [ref]$seconds)) {
        return [datetimeoffset]::FromUnixTimeSeconds($seconds).UtcDateTime.ToString('o')
    }
    return ([datetimeoffset]::Parse([string]$Value)).UtcDateTime.ToString('o')
}

function Get-WatchlistMetadata {
    $raw = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $reportRows = [System.Collections.Generic.List[object]]::new()
    $watchlistRows = [System.Collections.Generic.List[object]]::new()
    $watchlistPath = [string](Get-PropertyValue -Object $script:Config -Path 'Paths.Watchlists' -Default '/threathunter/watchlistmgr/v3/orgs/{orgKey}/watchlists')
    if ($watchlistPath -eq '/watchlistmgr/v3/orgs/{orgKey}/watchlists') {
        $watchlistPath = '/threathunter/watchlistmgr/v3/orgs/{orgKey}/watchlists'
    }
    $reportPath = [string](Get-PropertyValue -Object $script:Config -Path 'Paths.Report' -Default '/threathunter/watchlistmgr/v3/orgs/{orgKey}/reports/{reportId}')
    $feedPath = [string](Get-PropertyValue -Object $script:Config -Path 'Paths.FeedReports' -Default '/threathunter/feedmgr/v2/orgs/{orgKey}/feeds/{feedId}/reports')
    $requests = [ordered]@{ $watchlistPath = 'Watchlists' }
    $feedIdsByPath = @{}
    $reportsSeen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($watchlistPath)
    while ($pending.Count -gt 0) {
        $path = $pending.Dequeue()
        Write-AnalyticsStatus ("Fetching {0} metadata; {1} queued requests remain." -f $requests[$path], $pending.Count)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-CbcRequest -Method GET -Path $path
        } catch {
            $message = "Metadata unavailable for $path. $($_.Exception.Message)"
            $warnings.Add($message)
            $raw.Add([pscustomobject]@{ Operation = $requests[$path]; Method = 'GET'; Path = $path; Response = $null; Error = $message })
            Write-AnalyticsStatus $message
            continue
        }
        $raw.Add([pscustomobject]@{ Operation = $requests[$path]; Method = 'GET'; Path = $path; Response = $response })
        Write-AnalyticsStatus ("Metadata received; elapsed {0}." -f $timer.Elapsed.ToString('c'))
        if ($path -eq $watchlistPath) {
            foreach ($watchlist in @(Get-ResponseItems -Response $response)) {
                $watchlistRows.Add([pscustomobject]@{
                    Name = $watchlist.name
                    Id = $watchlist.id
                    AlertsEnabled = Get-PropertyValue -Object $watchlist -Path 'alerts_enabled' -Default 'Unknown'
                    Created = ConvertFrom-ApiTimestamp (Get-PropertyValue -Object $watchlist -Path 'create_timestamp')
                    Updated = ConvertFrom-ApiTimestamp (Get-PropertyValue -Object $watchlist -Path 'last_update_timestamp')
                })
                $reportIds = Get-PropertyValue -Object $watchlist -Path 'report_ids' -Default @()
                foreach ($reportId in $reportIds) {
                    $nextPath = $reportPath.Replace('{reportId}', [uri]::EscapeDataString([string]$reportId))
                    if (-not $requests.Contains($nextPath)) {
                        $requests[$nextPath] = 'CustomReport'
                        $pending.Enqueue($nextPath)
                    }
                }
                if ((Get-PropertyValue -Object $watchlist -Path 'classifier.key') -eq 'feed_id') {
                    $feedId = [string](Get-PropertyValue -Object $watchlist -Path 'classifier.value')
                    $nextPath = $feedPath.Replace('{feedId}', [uri]::EscapeDataString($feedId))
                    $feedIdsByPath[$nextPath] = $feedId
                    if (-not $requests.Contains($nextPath)) {
                        $requests[$nextPath] = 'FeedReports'
                        $pending.Enqueue($nextPath)
                    }
                }
            }
        } else {
            foreach ($report in @(Get-ResponseItems -Response $response)) {
                $id = [string]$report.id
                if ($feedIdsByPath.ContainsKey($path)) {
                    $prefix = '{0}-' -f $feedIdsByPath[$path]
                    if (-not $id.StartsWith($prefix, [System.StringComparison]::Ordinal)) { $id = $prefix + $id }
                }
                if (-not $reportsSeen.Add($id)) { continue }
                $reportRows.Add([pscustomobject]@{
                    Name = [string]$report.title
                    Id = $id
                    Source = $path
                    Created = ConvertFrom-ApiTimestamp (Get-PropertyValue -Object $report -Path 'create_timestamp')
                    Updated = ConvertFrom-ApiTimestamp (Get-PropertyValue -Object $report -Path 'last_update_timestamp')
                    ReportTimestamp = ConvertFrom-ApiTimestamp (Get-PropertyValue -Object $report -Path 'timestamp')
                })
            }
        }
    }
    return [pscustomobject]@{ Watchlists = $watchlistRows.ToArray(); Reports = $reportRows.ToArray(); Raw = $raw.ToArray(); Warnings = $warnings.ToArray() }
}

function New-AggregateAnalytics {
    param(
        [Parameter(Mandatory = $true)]$Aggregations,
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][datetime]$StartDate,
        [Parameter(Mandatory = $true)][datetime]$EndDate
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($message in $Metadata.Warnings) { $warnings.Add($message) }
    $warnings.Add('Rankings cover WATCHLIST alerts only. PercentOfAllAlerts uses the all-type count with the configured filters; PercentOfWatchlistAlerts uses the WATCHLIST count with those filters.')
    $warnings.Add('Facets return top values, not a complete inventory. Report names may combine multiple report IDs; device names may combine multiple devices. Missing or multi-valued fields mean percentages need not sum to 100. Counts are separate API snapshots.')
    $warnings.Add('Report timestamp is publisher-supplied metadata, not a verified creation or update date. Unavailable creation/update dates are marked explicitly. Current metadata may differ from historical alert names.')
    $warnings.Add('Recommendations are review priorities only. Disable a report only after confirming it is benign, redundant or no longer required and obtaining approval. Volume or absence from a ranking is not sufficient evidence.')
    $rankings = @{}
    $coverage = @(foreach ($field in @('report_name', 'device_name', 'process_username')) {
        $ranking = Get-FacetRanking -Aggregations $Aggregations -Field $field
        $rankings[$field] = $ranking.Rows
        if ($ranking.AtLimit) { $warnings.Add("$field reached the requested facet limit ($($Aggregations.FacetRows)); additional values may be omitted.") }
        [pscustomobject]@{ Field = $field; ReturnedValues = $ranking.Rows.Count; RequestedLimit = $Aggregations.FacetRows; AtLimit = $ranking.AtLimit; Status = $ranking.Status }
    })
    $threshold = [int64](Get-PropertyValue -Object $script:Config -Path 'Recommendation.HighAlertThreshold' -Default 100000)
    foreach ($row in $rankings.report_name) {
        $recommendation = if ($row.Alerts -ge $threshold) { 'Prioritize tuning review; validate false positives before changing detection' } else { 'Review context; no disable decision from volume alone' }
        $row | Add-Member -NotePropertyName Recommendation -NotePropertyValue $recommendation
    }
    $trend = @()
    if ($Aggregations.WatchlistAlerts -gt 0) {
        if ($null -eq $Aggregations.Histogram.PSObject.Properties['results']) { throw 'Histogram response is missing results.' }
        $trend = @(foreach ($bucket in $Aggregations.Histogram.results) {
            $count = [int64]0
            if (-not [int64]::TryParse([string]$bucket.total, [ref]$count) -or $count -lt 0) { throw 'Invalid histogram count.' }
            [pscustomobject]@{ StartUtc = [string]$bucket.step_start; Alerts = $count }
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 2
        Mode = 'ServerSideAggregations'
        GeneratedAt = [datetime]::UtcNow.ToString('o')
        StartDate = $StartDate.ToUniversalTime().ToString('o')
        EndDate = $EndDate.ToUniversalTime().ToString('o')
        TotalAlerts = $Aggregations.TotalAlerts
        WatchlistAlerts = $Aggregations.WatchlistAlerts
        FacetRows = $Aggregations.FacetRows
        Warnings = $warnings.ToArray()
        Coverage = $coverage
        Reports = $rankings.report_name
        Endpoints = $rankings.device_name
        Users = $rankings.process_username
        DailyAlerts = $trend
        Watchlists = $Metadata.Watchlists
        ReportMetadata = $Metadata.Reports
        Raw = [ordered]@{ Aggregations = $Aggregations.Raw; Metadata = $Metadata.Raw }
    }
}

function ConvertTo-HtmlTable {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows)
    if ($Rows.Count -eq 0) { return '<p class="muted">No data returned.</p>' }
    return ($Rows | ConvertTo-Html -Fragment | Out-String)
}

function ConvertTo-ReportMetadataHtml {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][uri]$BaseUrl,
        [AllowEmptyCollection()][object[]]$RankedReports = @()
    )

    if (-not $BaseUrl.IsAbsoluteUri -or $BaseUrl.Scheme -ne 'https') {
        throw 'Report links require an absolute HTTPS BaseUrl.'
    }
    if ($Rows.Count -eq 0) { return ConvertTo-HtmlTable -Rows @() }
    $topNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rankedReport in @($RankedReports | Sort-Object Alerts -Descending | Select-Object -First 50)) {
        if ($rankedReport.Alerts -gt 0) { $null = $topNames.Add([string]$rankedReport.Name) }
    }
    $sortedRows = @($Rows | Sort-Object ReportTimestamp | Select-Object Name, Id, Source, ReportTimestamp, @{ Name = 'Top 50'; Expression = { '' } })
    [xml]$table = ConvertTo-HtmlTable -Rows $sortedRows
    $tableRows = @($table.SelectNodes('/table/tr[td]'))
    for ($index = 0; $index -lt $sortedRows.Count; $index++) {
        $markerCell = $tableRows[$index].SelectNodes('td')[4]
        $isTop = $topNames.Contains([string]$sortedRows[$index].Name)
        $markerCell.SetAttribute('data-sort-value', [string][int]$isTop)
        if ($isTop) {
            $marker = $table.CreateElement('span')
            $marker.SetAttribute('class', 'top-report')
            $marker.SetAttribute('role', 'img')
            $description = 'Top 50: name appears in the returned report-name ranking. Names may represent multiple report IDs.'
            $marker.SetAttribute('title', $description)
            $marker.SetAttribute('aria-label', $description)
            $marker.InnerText = ([string][char]9733) + ' 50'
            $null = $markerCell.AppendChild($marker)
        }
        $sourceCell = $tableRows[$index].SelectNodes('td')[2]
        $sourceCell.RemoveAll()
        if ([string]::IsNullOrWhiteSpace([string]$sortedRows[$index].Id)) {
            $sourceCell.InnerText = 'Report link unavailable'
            continue
        }
        $url = '{0}/enforce/watchlists/report/{1}' -f $BaseUrl.GetLeftPart([System.UriPartial]::Authority), [uri]::EscapeDataString([string]$sortedRows[$index].Id)
        $link = $table.CreateElement('a')
        $link.SetAttribute('href', $url)
        $link.InnerText = 'View report'
        $null = $sourceCell.AppendChild($link)
    }
    return $table.OuterXml
}

function New-HtmlReport {
    param(
        [Parameter(Mandatory = $true)]$Analytics,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $title = 'Carbon Black Cloud Watchlist Analytics'
    $css = @'
body{font-family:Segoe UI,Arial,sans-serif;color:#1f2933;margin:2rem;line-height:1.4}h1{color:#123b5d}h2{border-bottom:2px solid #d9e2ec;padding-bottom:.35rem;margin-top:2rem}table{border-collapse:collapse;width:100%;margin:1rem 0;font-size:.9rem}th{background:#123b5d;color:white;text-align:left}td,th{border:1px solid #bcccdc;padding:.45rem;vertical-align:top}tr:nth-child(even){background:#f0f4f8}.summary{display:flex;gap:1rem;flex-wrap:wrap}.metric{border-left:4px solid #2f80ed;background:#f0f4f8;padding:.8rem 1.2rem;min-width:12rem}.metric strong{display:block;font-size:1.5rem}.muted{color:#627d98}.warning{background:#fff3cd;border-left:4px solid #f0ad4e;padding:.8rem}
'@
    $css += @'
th button{font:inherit;font-weight:600;color:inherit;background:transparent;border:0;padding:0;display:flex;align-items:center;justify-content:space-between;gap:.6rem;width:100%;text-align:left;cursor:pointer}th button:focus-visible{outline:2px solid #fff;outline-offset:3px}.sort-indicator{min-width:1em}.top-report{display:inline-block;white-space:nowrap;color:#805300;background:#fff3cd;border:1px solid #d8b44b;border-radius:4px;padding:.1rem .35rem}td{overflow-wrap:anywhere}.table-scroll{overflow-x:auto}
'@
    $sortScript = @'
<script type="text/javascript">
(() => {
    const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
    document.querySelectorAll('table').forEach(table => {
        const wrapper = document.createElement('div');
        wrapper.className = 'table-scroll';
        table.before(wrapper);
        wrapper.append(table);
        const headers = Array.from(table.querySelectorAll('th'));
        const rows = Array.from(table.querySelectorAll('tr')).filter(row => row.querySelector('td'));
        const originalOrder = new Map(rows.map((row, index) => [row, index]));
        const sortColumns = [];
        headers.forEach((header, column) => {
            const label = header.textContent.trim();
            const numeric = /^(Alerts|PercentOfWatchlistAlerts|PercentOfAllAlerts|Top 50)$/.test(label);
            const date = /^(Created|Updated|ReportTimestamp)$/.test(label);
            header.scope = 'col';
            header.setAttribute('aria-sort', 'none');
            const button = document.createElement('button');
            button.type = 'button';
            button.title = 'Sort by ' + label;
            button.setAttribute('aria-label', 'Sort by ' + label);
            button.append(document.createTextNode(label));
            const indicator = document.createElement('span');
            indicator.className = 'sort-indicator';
            indicator.setAttribute('aria-hidden', 'true');
            indicator.textContent = '\u2195';
            button.append(indicator);
            header.replaceChildren(button);
            button.addEventListener('click', event => {
                const existingIndex = sortColumns.findIndex(sort => sort.column === column);
                if (event.shiftKey) {
                    if (existingIndex === -1) {
                        sortColumns.push({ column, direction: 1, numeric, date, label });
                    } else {
                        sortColumns[existingIndex].direction *= -1;
                    }
                } else {
                    const direction = existingIndex === 0 ? sortColumns[existingIndex].direction * -1 : 1;
                    sortColumns.splice(0, sortColumns.length, { column, direction, numeric, date, label });
                }
                const value = (row, sort) => {
                    const cell = row.cells[sort.column];
                    const text = (cell.dataset.sortValue ?? cell.textContent).trim();
                    if (!text || /^(Not provided by API|Unknown|Unavailable|Report link unavailable)$/.test(text)) return null;
                    if (sort.numeric) return Number.isFinite(Number(text)) ? Number(text) : null;
                    if (sort.date) return Number.isFinite(Date.parse(text)) ? Date.parse(text) : null;
                    return text;
                };
                rows.sort((left, right) => {
                    for (const sort of sortColumns) {
                        const leftValue = value(left, sort);
                        const rightValue = value(right, sort);
                        if (leftValue === null && rightValue === null) continue;
                        if (leftValue === null) return 1;
                        if (rightValue === null) return -1;
                        const comparison = sort.numeric || sort.date
                            ? leftValue - rightValue
                            : collator.compare(leftValue, rightValue);
                        if (comparison !== 0) return comparison * sort.direction;
                    }
                    return originalOrder.get(left) - originalOrder.get(right);
                });
                const parent = rows[0]?.parentElement;
                rows.forEach(row => parent.append(row));
                headers.forEach((other, otherColumn) => {
                    const sortIndex = sortColumns.findIndex(sort => sort.column === otherColumn);
                    other.setAttribute('aria-sort', 'none');
                    const otherButton = other.querySelector('button');
                    const otherIndicator = other.querySelector('.sort-indicator');
                    if (sortIndex === -1) {
                        const otherLabel = otherButton.textContent.replace(/\s*[\u2191\u2193\u2195]\d*$/, '');
                        otherButton.title = 'Sort by ' + otherLabel;
                        otherButton.setAttribute('aria-label', 'Sort by ' + otherLabel);
                        otherIndicator.textContent = '\u2195';
                        return;
                    }
                    const sort = sortColumns[sortIndex];
                    const directionName = sort.direction === 1 ? 'ascending' : 'descending';
                    otherButton.title = `Sort by ${sort.label}; priority ${sortIndex + 1}, ${directionName}`;
                    otherButton.setAttribute('aria-label', `Sort by ${sort.label}; priority ${sortIndex + 1}, ${directionName}`);
                    otherIndicator.textContent = (sort.direction === 1 ? '\u2191' : '\u2193') + (sortIndex + 1);
                    if (sortIndex === 0) other.setAttribute('aria-sort', directionName);
                });
            });
        });
    });
})();
</script>
'@
    $warnings = if ($Analytics.Warnings.Count -gt 0) { '<div class="warning"><strong>Warnings</strong><ul>' + (($Analytics.Warnings | ForEach-Object { '<li>' + [System.Net.WebUtility]::HtmlEncode($_) + '</li>' }) -join '') + '</ul></div>' } else { '' }
    $reportMetadataHtml = ConvertTo-ReportMetadataHtml -Rows $Analytics.ReportMetadata -BaseUrl $script:Config.BaseUrl -RankedReports $Analytics.Reports
    $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>$title</title><style>$css</style></head><body>
<h1>$title</h1><p class="muted">Generated $($Analytics.GeneratedAt) | Window: $($Analytics.StartDate) to $($Analytics.EndDate)</p>
$warnings
<div class="summary"><div class="metric"><strong>$($Analytics.TotalAlerts)</strong>All alert types (configured filters)</div><div class="metric"><strong>$($Analytics.WatchlistAlerts)</strong>Watchlist alerts</div><div class="metric"><strong>$($Analytics.FacetRows)</strong>Requested facet limit</div></div>
<h2>Top report names: watchlist alerts</h2>$(ConvertTo-HtmlTable -Rows $Analytics.Reports)
<h2>Top endpoint names: watchlist alerts</h2>$(ConvertTo-HtmlTable -Rows $Analytics.Endpoints)
<h2>Top process users: watchlist alerts</h2>$(ConvertTo-HtmlTable -Rows $Analytics.Users)
<h2>Current watchlist metadata</h2>$(ConvertTo-HtmlTable -Rows $Analytics.Watchlists)
<h2>Current report metadata</h2>$reportMetadataHtml
$sortScript
</body></html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

$runTimer = [System.Diagnostics.Stopwatch]::StartNew()
Write-AnalyticsStatus 'Starting watchlist analytics; loading configuration.'
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file was not found: $ConfigPath" }
$script:Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Config.BaseUrl) -or [string]::IsNullOrWhiteSpace($Config.OrgKey) -or [string]::IsNullOrWhiteSpace($Config.ApiId)) { throw 'Config must contain BaseUrl, OrgKey, and ApiId.' }
if ([string]$Config.OrgKey -match '^REPLACE_WITH_' -or [string]$Config.ApiId -match '^REPLACE_WITH_') { throw "Config '$ConfigPath' still contains placeholder credentials. Pass -ConfigPath with a populated Carbon Black config." }
$secretVariable = Get-ConfigValue -Object $Config -Name 'ApiSecretEnvironmentVariable' -Default 'CBC_API_SECRET'
$script:ApiSecret = [Environment]::GetEnvironmentVariable($secretVariable)
if ([string]::IsNullOrWhiteSpace($script:ApiSecret)) { throw "Set the API secret in environment variable '$secretVariable'." }

$defaultEnd = (Get-Date).ToUniversalTime()
$defaultStart = $defaultEnd.AddDays(-7)
if (-not $PSBoundParameters.ContainsKey('EndDate')) { $EndDate = $defaultEnd }
if (-not $PSBoundParameters.ContainsKey('StartDate')) { $StartDate = $defaultStart }
$dateWindow = Resolve-AlertDateWindow -StartDate $StartDate -EndDate $EndDate -Now $defaultEnd
$StartDate = $dateWindow.StartDate
$EndDate = $dateWindow.EndDate
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$jsonPath = Join-Path $OutputDirectory 'watchlist-analytics.json'
$htmlPath = Join-Path $OutputDirectory 'watchlist-analytics.html'
$facetRows = [int](Get-PropertyValue -Object $Config -Path 'Analytics.FacetRows' -Default 50)
Write-AnalyticsStatus 'Using server-side analytics. Legacy hourly slicing and alert row settings are ignored.'
$aggregations = Get-AlertAggregations -StartDate $StartDate -EndDate $EndDate -FacetRows $facetRows
Write-AnalyticsStatus ("Saving aggregate responses before metadata collection: {0}" -f $jsonPath)
[ordered]@{
    SchemaVersion = 2
    Mode = 'ServerSideAggregations'
    Status = 'Aggregations collected; metadata and report pending'
    StartDate = $StartDate.ToString('o')
    EndDate = $EndDate.ToString('o')
    Raw = @{ Aggregations = $aggregations.Raw }
} | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$metadata = Get-WatchlistMetadata
Write-AnalyticsStatus ("Building aggregate rankings and metadata tables; elapsed {0}." -f $runTimer.Elapsed.ToString('c'))
$result = New-AggregateAnalytics -Aggregations $aggregations -Metadata $metadata -StartDate $StartDate -EndDate $EndDate
Write-AnalyticsStatus ("Writing JSON: {0}" -f $jsonPath)
$result | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-AnalyticsStatus ("Writing HTML: {0}" -f $htmlPath)
New-HtmlReport -Analytics ([pscustomobject]$result) -Path $htmlPath
$runTimer.Stop()
Write-AnalyticsStatus ("Finished: {0} watchlist alerts summarized, {1} report-name groups returned; no individual alerts downloaded; total elapsed {2}." -f $result.WatchlistAlerts, $result.Reports.Count, $runTimer.Elapsed.ToString('c'))
Write-Output "Wrote $htmlPath"
Write-Output "Wrote $jsonPath"