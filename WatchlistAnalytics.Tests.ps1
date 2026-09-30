[CmdletBinding()]
param([string]$ScriptPath = (Join-Path $PSScriptRoot 'WatchlistAnalytics.ps1'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$parseErrors = $null
$source = Get-Content -LiteralPath $ScriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput(
    $source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Script syntax validation failed.' }
$definitions = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)

& {
    param($definitions, $source)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }

    function Assert-True {
        param([bool]$Condition, [string]$Message)
        if (-not $Condition) { throw $Message }
    }

    $now = [datetime]::Parse('2026-09-30T12:00:00Z').ToUniversalTime()
    $cutoff = $now.AddDays(-180).AddMinutes(5)
    $cases = @(
        @{ Name = 'Expired start'; Start = $now.AddDays(-250); End = $now.AddDays(-30); ExpectedStart = $cutoff; ExpectedEnd = $now.AddDays(-30); InfoCount = 1 },
        @{ Name = 'Valid range'; Start = $now.AddDays(-7); End = $now; ExpectedStart = $now.AddDays(-7); ExpectedEnd = $now; InfoCount = 0 },
        @{ Name = 'Entirely expired'; Start = $now.AddDays(-250); End = $now.AddDays(-200); ExpectedStart = $cutoff; ExpectedEnd = $now; InfoCount = 1 },
        @{ Name = 'Exact retention boundary'; Start = $now.AddDays(-180); End = $now; ExpectedStart = $cutoff; ExpectedEnd = $now; InfoCount = 1 },
        @{ Name = 'Buffered boundary'; Start = $cutoff; End = $now; ExpectedStart = $cutoff; ExpectedEnd = $now; InfoCount = 0 },
        @{ Name = 'Future end'; Start = $now.AddDays(-7); End = $now.AddDays(1); ExpectedStart = $now.AddDays(-7); ExpectedEnd = $now; InfoCount = 1 },
        @{ Name = 'Local dates'; Start = $now.AddDays(-7).ToLocalTime(); End = $now.ToLocalTime(); ExpectedStart = $now.AddDays(-7); ExpectedEnd = $now; InfoCount = 0 }
    )
    foreach ($case in $cases) {
        $output = @(Resolve-AlertDateWindow -StartDate $case.Start -EndDate $case.End -Now $now 6>&1)
        $messages = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
        $windows = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        Assert-True ($windows.Count -eq 1) "$($case.Name): INFO contaminated returned dates."
        Assert-True ($windows[0].StartDate -eq $case.ExpectedStart -and $windows[0].EndDate -eq $case.ExpectedEnd) "$($case.Name): incorrect window."
        Assert-True ($windows[0].StartDate.Kind -eq 'Utc' -and $windows[0].EndDate.Kind -eq 'Utc') "$($case.Name): dates not UTC."
        Assert-True ($messages.Count -eq $case.InfoCount) "$($case.Name): incorrect INFO count."
        if ($messages.Count) {
            Assert-True ($messages[0].MessageData -like 'INFO:*180-day*five-minute*') 'Retention INFO missing context.'
            Assert-True ($messages[0].MessageData.Contains($case.ExpectedStart.ToString('o'))) 'Effective date absent from INFO.'
        }
    }
    foreach ($invalidWindow in @(
        @{ Start = $now; End = $now },
        @{ Start = $now; End = $now.AddDays(-1) },
        @{ Start = $now.AddDays(1); End = $now.AddDays(2) }
    )) {
        $message = ''
        try { $null = Resolve-AlertDateWindow -StartDate $invalidWindow.Start -EndDate $invalidWindow.End -Now $now } catch { $message = $_.Exception.Message }
        Assert-True ($message -match 'must be') 'Invalid date window accepted.'
    }

    $script:Config = @'
{"BaseUrl":"https://example.invalid","OrgKey":"test-org","ApiId":"test-id","ApiSecretEnvironmentVariable":"TEST_ONLY","AlertSearch":{"Path":"/api/alerts/v7/orgs/{orgKey}/alerts/_search","TimeField":"create_time","TotalField":"num_found","RowsPerRequest":10000,"BodyTemplate":{"criteria":{"type":["WATCHLIST"]},"start":0,"rows":10000,"time_range":{"range":"-2w"}}}}
'@ | ConvertFrom-Json
    $script:ApiSecret = 'dummy-secret'
    $before = $script:Config | ConvertTo-Json -Depth 30
    $start = [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime()
    $end = $start.AddHours(1)
    $body = New-AnalyticsFilter -StartDate $start -EndDate $end -WatchlistOnly
    $json = $body | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    Assert-True ($json.time_range.start -ceq '2026-01-01T00:00:00.000Z') 'Incorrect UTC start.'
    Assert-True ($json.time_range.end -ceq '2026-01-01T01:00:00.000Z') 'Incorrect UTC end.'
    Assert-True ($null -eq $json.time_range.PSObject.Properties['range']) 'Relative range was retained.'
    Assert-True ($null -eq $json.criteria.PSObject.Properties['create_time']) 'Invalid time criterion.'
    Assert-True ($json.criteria.type[0] -eq 'WATCHLIST') 'Criteria lost.'
    Assert-True ($null -eq $json.PSObject.Properties['start'] -and $null -eq $json.PSObject.Properties['rows']) 'Pagination leaked into aggregate filters.'
    Assert-True (($script:Config | ConvertTo-Json -Depth 30) -ceq $before) 'Template mutated.'

    $script:ResponseMode = 'success'
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $ErrorAction, $ContentType, $Body)
        Assert-True ($Headers['X-Auth-Token'] -ceq 'dummy-secret/test-id') 'Wrong token order.'
        Assert-True ($Uri -ceq 'https://example.invalid/api/alerts/v7/orgs/test-org/alerts/_search') 'Wrong URL.'
        Assert-True ($Method -eq 'POST' -and $ContentType -eq 'application/json') 'Wrong method or content type.'
        Assert-True (($Body | ConvertFrom-Json).start -eq 1) 'Serialized pagination incorrect.'
        if ($script:ResponseMode -eq 'success') { return [pscustomobject]@{ results = @(); num_found = 0 } }
        if ($script:ResponseMode -eq 'non-http') { throw [System.InvalidOperationException]::new('Mock transport failure') }
        $response = [pscustomobject]@{ StatusCode = 400 }
        $response | Add-Member -MemberType ScriptMethod -Name GetResponseStream -Value {
            return [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes('{"message":"Invalid rows dummy-secret"}'))
        }
        $exception = [System.Exception]::new('Bad Request')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'MockHttp400', 'InvalidOperation', $null)
        if ($script:ResponseMode -eq 'details') {
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('{"message":"Invalid rows dummy-secret"}')
        }
        throw $record
    }
    foreach ($mode in @('details', 'stream', 'non-http')) {
        $script:ResponseMode = $mode
        $message = ''
        try { $null = Invoke-CbcRequest -Method POST -Path $script:Config.AlertSearch.Path -Body @{ rows = 0; start = 1 } } catch { $message = $_.Exception.Message }
        if ($mode -eq 'non-http') {
            Assert-True ($message -eq 'Mock transport failure') 'Non-HTTP exception masked.'
        } else {
            Assert-True ($message -match 'HTTP 400' -and $message -match 'POST https://example.invalid/' -and $message -match 'Invalid rows') 'HTTP context or response body lost.'
            Assert-True ($message -notmatch 'dummy-secret' -and $message -match '\[REDACTED\]') 'Secret not redacted.'
        }
    }
    & {
        function Invoke-CbcRequest {
            param($Method, $Path, $Body)
            if ($Path.EndsWith('/_search')) {
                Assert-True ($Body.rows -eq 0) 'Facet limit test requested alert records.'
                return [pscustomobject]@{ num_found = 100; results = @() }
            }
            if ($Path.EndsWith('/_facet')) {
                Assert-True ($Body.terms.rows -ge 1 -and $Body.terms.rows -le 50) 'Facet request exceeds API limit.'
                return [pscustomobject]@{ results = @([pscustomobject]@{
                    field = 'report_name'
                    values = @(1..$Body.terms.rows | ForEach-Object { [pscustomobject]@{ id = "report-$_"; name = "Report $_"; total = 1 } })
                }) }
            }
            return [pscustomobject]@{ results = @() }
        }
        foreach ($requestedRows in @($null, 2, 50, 100, 10000)) {
            $parameters = @{ StartDate = $start; EndDate = $end }
            if ($null -ne $requestedRows) { $parameters.FacetRows = $requestedRows }
            $output = @(Get-AlertAggregations @parameters 6>&1)
            $messages = @($output | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
            $results = @($output | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            $expectedRows = if ($null -eq $requestedRows) { 50 } else { [math]::Min($requestedRows, 50) }
            Assert-True ($results.Count -eq 1 -and $results[0].FacetRows -eq $expectedRows) 'Incorrect effective facet limit.'
            $facetRequest = @($results[0].Raw | Where-Object { $_.Operation -eq 'WatchlistFacets' })
            Assert-True ($facetRequest.Count -eq 1 -and $facetRequest[0].Request.terms.rows -eq $expectedRows) 'Raw JSON does not reflect effective limit.'
            $adjustments = @($messages | Where-Object { $_.MessageData -like '*FacetRows adjusted*' })
            $expectedMessages = if ($null -ne $requestedRows -and $requestedRows -gt 50) { 1 } else { 0 }
            Assert-True ($adjustments.Count -eq $expectedMessages) 'Incorrect facet adjustment INFO output.'
            $ranking = Get-FacetRanking -Aggregations $results[0] -Field 'report_name'
            Assert-True ($ranking.AtLimit -and $ranking.Rows.Count -eq $expectedRows) 'Coverage did not use effective facet limit.'
        }
        'PASS: facet defaults, clamping, smaller limits, INFO output, raw request and coverage'
    }
    $script:Config.AlertSearch.BodyTemplate.criteria.type = @('CB_ANALYTICS')
    $message = ''
    try { $null = New-AnalyticsFilter -StartDate $start -EndDate $end -WatchlistOnly } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'must include WATCHLIST') 'Conflicting type filter silently overwritten.'

    function Invoke-MockedWorkflow {
        param([string]$Scenario)
        & {
            param($Scenario, $source)
            $script:scenario = $Scenario
            $script:calls = [System.Collections.Generic.List[object]]::new()
            $script:writes = [System.Collections.Generic.List[object]]::new()
            function Test-Path { param($LiteralPath) return $true }
            function Get-Content {
                param($LiteralPath, [switch]$Raw)
                return '{"BaseUrl":"https://example.invalid","OrgKey":"test-org","ApiId":"test-id","ApiSecretEnvironmentVariable":"WATCHLIST_ANALYTICS_TEST_ONLY","Paths":{"Watchlists":"/watchlistmgr/v3/orgs/{orgKey}/watchlists","Reports":"/obsolete"},"Analytics":{"FacetRows":2},"AlertSearch":{"SliceHours":1,"RowsPerRequest":10000,"BodyTemplate":{"criteria":{"device_os":["WINDOWS"]},"exclusions":{"workflow_status":["CLOSED"]},"query":"severity:4","rows":10000,"start":0}}}'
            }
            function New-Item { param($ItemType, $Path, [switch]$Force) }
            function Set-Content {
                param($LiteralPath, [Parameter(ValueFromPipeline=$true)]$Value, $Encoding)
                process { $script:writes.Add([pscustomobject]@{ Path = $LiteralPath; Value = [string]$Value }) }
            }
            function Invoke-RestMethod {
                param($Uri, $Method, $Headers, $ErrorAction, $ContentType, $Body)
                Assert-True ($Headers['X-Auth-Token'] -ceq 'dummy-secret/test-id') 'Auth header changed.'
                $script:calls.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body })
                if ($Method -eq 'GET') {
                    Assert-True ($script:writes.Count -eq 1) 'Aggregations not checkpointed before metadata.'
                    if ($Uri.EndsWith('/watchlists')) {
                        if ($script:scenario -eq 'Empty') { return [pscustomobject]@{results=@()} }
                        return [pscustomobject]@{results=@(
                            [pscustomobject]@{id='w1';name='Custom';alerts_enabled=$true;create_timestamp=1604693936;last_update_timestamp=1604693936;report_ids=@('r1');classifier=$null},
                            [pscustomobject]@{id='w2';name='Feed';alerts_enabled=$false;report_ids=$null;classifier=[pscustomobject]@{key='feed_id';value='f1'}}
                        )}
                    }
                    if ($Uri.EndsWith('/reports/r1')) { return [pscustomobject]@{id='r1';title='Same title';timestamp=1604693936} }
                    if ($Uri.EndsWith('/feeds/f1/reports')) {
                        if ($script:scenario -eq 'MetadataFailure') { throw 'Mock feed access denied' }
                        return [pscustomobject]@{results=@([pscustomobject]@{id='r2';title='Same title';timestamp=1504693936})}
                    }
                    throw "Unexpected metadata route $Uri"
                }
                Assert-True ($Method -eq 'POST' -and $ContentType -eq 'application/json') 'Unexpected API method.'
                $request = $Body | ConvertFrom-Json
                Assert-True ($request.criteria.device_os[0] -eq 'WINDOWS' -and $request.query -eq 'severity:4' -and $request.exclusions.workflow_status[0] -eq 'CLOSED') 'Filters inconsistent.'
                if ($Uri.EndsWith('/_search')) {
                    Assert-True ($request.rows -eq 0 -and $request.start -eq 1) 'Individual alerts requested.'
                    if ($script:scenario -eq 'InvalidCount') { return [pscustomobject]@{results=@()} }
                    $count = if ($script:scenario -eq 'Empty') { 0 } elseif ($null -ne $request.criteria.PSObject.Properties['type']) { 4000000 } else { 8000000 }
                    return [pscustomobject]@{num_found=[string]$count;results=@()}
                }
                Assert-True ($request.criteria.type[0] -eq 'WATCHLIST') 'Aggregate scope not watchlist.'
                Assert-True ($null -eq $request.PSObject.Properties['rows'] -and $null -eq $request.PSObject.Properties['start']) 'Aggregate includes pagination.'
                if ($Uri.EndsWith('/_facet')) {
                    Assert-True ($request.filter_values -and ($request.terms.fields -join ',') -eq 'report_name,device_name,process_username') 'Wrong facet fields/filters.'
                    if ($script:scenario -eq 'MalformedFacet') { return [pscustomobject]@{results=@()} }
                    return [pscustomobject]@{results=@(foreach ($field in $request.terms.fields) {
                        [pscustomobject]@{field=$field;values=@(
                            [pscustomobject]@{id='one';name='Same title';total=3000000},
                            [pscustomobject]@{id='two';name='<script>alert(1)</script>';total=1000000}
                        )}
                    })}
                }
                if ($Uri.EndsWith('/_histogram')) {
                    Assert-True ($request.field -eq 'BACKEND_TIMESTAMP' -and $request.bucket_size -eq '+1DAY') 'Wrong histogram settings.'
                    return [pscustomobject]@{results=@([pscustomobject]@{step_start='2026-09-01T00:00:00Z';total=4000000})}
                }
                throw "Unexpected route $Uri"
            }
            $oldSecret = [Environment]::GetEnvironmentVariable('WATCHLIST_ANALYTICS_TEST_ONLY')
            try {
                [Environment]::SetEnvironmentVariable('WATCHLIST_ANALYTICS_TEST_ONLY', 'dummy-secret')
                $errorMessage = ''
                $log = @()
                try {
                    $log = @(& ([scriptblock]::Create($source)) -ConfigPath 'mock.json' -OutputDirectory $env:TEMP -StartDate ([datetime]::UtcNow.AddDays(-30)) -EndDate ([datetime]::UtcNow.AddDays(-1)) 6>&1)
                } catch { $errorMessage = $_.Exception.Message }
                if ($Scenario -eq 'InvalidCount') {
                    Assert-True ($errorMessage -match 'valid num_found' -and $script:writes.Count -eq 0) 'Invalid count accepted.'
                    return
                }
                if ($Scenario -eq 'MalformedFacet') {
                    Assert-True ($errorMessage -match 'Facet response is missing values' -and $script:writes.Count -eq 1) 'Malformed facets accepted or checkpoint missing.'
                    return
                }
                Assert-True ([string]::IsNullOrEmpty($errorMessage)) "Workflow failed: $errorMessage"
                $jsonWrites = @($script:writes | Where-Object { $_.Path.EndsWith('.json') })
                $htmlWrites = @($script:writes | Where-Object { $_.Path.EndsWith('.html') })
                Assert-True ($jsonWrites.Count -eq 2 -and $htmlWrites.Count -eq 1) 'Missing JSON checkpoint/final or HTML.'
                $result = $jsonWrites[-1].Value | ConvertFrom-Json
                $html = $htmlWrites[0].Value
                Assert-True ($result.SchemaVersion -eq 2 -and $null -eq $result.PSObject.Properties['Alerts']) 'Wrong JSON contract.'
                Assert-True ($jsonWrites[-1].Value -notmatch 'dummy-secret|X-Auth-Token') 'Credentials in output.'
                Assert-True ($html -notmatch '<h2>Daily watchlist alerts|<h2>Ranking coverage|Time slices') 'Removed HTML sections still present.'
                Assert-True ($html -match 'event\.shiftKey' -and $html -match 'const sortColumns = \[\]' -and $html -match 'priority \$\{sortIndex \+ 1\}') 'HTML multi-column sorting controls missing.'
                Assert-True ($html -match 'return originalOrder\.get\(left\) - originalOrder\.get\(right\)') 'HTML sorting is not stable.'
                $reportSection = ($html -split '<h2>Current report metadata</h2>')[1]
                Assert-True ($reportSection -notmatch '<th>Created</th>|<th>Updated</th>') 'Report metadata still displays Created/Updated.'
                Assert-True ($null -ne $result.PSObject.Properties['DailyAlerts'] -and $null -ne $result.PSObject.Properties['Coverage']) 'HTML changes removed JSON data.'
                $status = @($log | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
                Assert-True (@($status | Where-Object { $_.MessageData -match 'Finished:.*total elapsed' }).Count -eq 1) 'Final elapsed status missing.'
                $postCalls = @($script:calls | Where-Object { $_.Method -eq 'POST' })
                if ($Scenario -eq 'Empty') {
                    Assert-True ($postCalls.Count -eq 2 -and $result.Reports.Count -eq 0 -and $result.TotalAlerts -eq 0 -and $html -match 'No data returned') 'Zero-alert workflow incorrect.'
                } else {
                    Assert-True ($postCalls.Count -eq 4 -and $result.WatchlistAlerts -eq 4000000 -and $result.TotalAlerts -eq 8000000) 'API request count scales with alert count.'
                    Assert-True ($result.Reports[0].Alerts -eq 3000000 -and $result.Reports[0].PercentOfWatchlistAlerts -eq 75 -and $result.Reports[0].PercentOfAllAlerts -eq 37.5) 'Facet ranking/denominator incorrect.'
                    Assert-True ($result.Coverage[0].AtLimit -and ($result.Warnings -join ' ') -match 'may be omitted') 'Facet coverage warning missing.'
                    Assert-True ($result.Reports.Count -eq 2 -and ($result.Warnings -join ' ') -match 'multiple report IDs') 'Names misrepresented as unique reports.'
                    Assert-True ($result.ReportMetadata[0].Created -eq 'Not provided by API') 'Publisher timestamp mislabeled as creation.'
                    Assert-True ($result.Watchlists[1].AlertsEnabled -eq $false) 'Disabled metadata lost.'
                    Assert-True ($html -notmatch '<script>' -and $html -match '&lt;script&gt;') 'HTML values not encoded.'
                    if ($Scenario -eq 'MetadataFailure') {
                        Assert-True (($result.Warnings -join ' ') -match 'Mock feed access denied' -and $result.ReportMetadata.Count -eq 1) 'Missing metadata not disclosed.'
                    } else {
                        Assert-True ($result.ReportMetadata.Count -eq 2 -and $result.Raw.Metadata.Count -eq 3) 'Metadata missing.'
                        Assert-True ($reportSection.IndexOf('<td>f1-r2</td>') -ge 0 -and $reportSection.IndexOf('<td>f1-r2</td>') -lt $reportSection.IndexOf('<td>r1</td>')) 'Report metadata not sorted by ReportTimestamp ascending.'
                        Assert-True ($reportSection -match '<th>ReportTimestamp</th>') 'ReportTimestamp column missing.'
                        Assert-True ($result.ReportMetadata[0].Id -eq 'r1') 'HTML sorting mutated JSON metadata order.'
                    }
                }
            } finally {
                [Environment]::SetEnvironmentVariable('WATCHLIST_ANALYTICS_TEST_ONLY', $oldSecret)
            }
        } $Scenario $source
    }
    & {
        function Invoke-CbcRequest {
            param($Method, $Path, $Body)
            if ($Path.EndsWith('/watchlists')) {
                return [pscustomobject]@{ results = @(
                    [pscustomobject]@{ id='feed-watchlist'; name='Feed'; classifier=[pscustomobject]@{ key='feed_id'; value='feedA' } },
                    [pscustomobject]@{ id='custom-watchlist'; name='Custom'; report_ids=@('feedA-568483','custom-id') },
                    [pscustomobject]@{ id='other-feed'; name='Other feed'; classifier=[pscustomobject]@{ key='feed_id'; value='feedB' } }
                ) }
            }
            if ($Path -match '/feeds/feed[AB]/reports$') {
                return [pscustomobject]@{ results = @(
                    [pscustomobject]@{ id='568483'; title='Same name'; timestamp=1604693936 },
                    [pscustomobject]@{ id='local-uuid'; title='UUID report'; timestamp=1604693936 }
                ) }
            }
            if ($Path.EndsWith('/reports/feedA-568483')) { return [pscustomobject]@{ id='feedA-568483'; title='Same name'; timestamp=1604693936 } }
            if ($Path.EndsWith('/reports/custom-id')) { return [pscustomobject]@{ id='custom-id'; title='Same name'; timestamp=1604693936 } }
            throw "Unexpected metadata path $Path"
        }
        $metadata = Get-WatchlistMetadata 6>$null
        $ids = @($metadata.Reports.Id)
        Assert-True ($ids.Count -eq 5 -and @($ids | Where-Object { $_ -eq 'feedA-568483' }).Count -eq 1) 'Feed/custom duplicate not merged.'
        Assert-True ($ids -contains 'feedB-568483' -and $ids -contains 'custom-id') 'Same names or local IDs from different feeds were merged.'
        Assert-True ($ids -contains 'feedA-local-uuid' -and $ids -notcontains '568483') 'Feed-local IDs not qualified.'
        $feedRaw = @($metadata.Raw | Where-Object { $_.Operation -eq 'FeedReports' })
        Assert-True ($feedRaw[0].Response.results[0].id -eq '568483') 'Raw feed response was mutated.'
        $html = ConvertTo-ReportMetadataHtml -Rows $metadata.Reports -BaseUrl 'https://example.invalid'
        Assert-True ($html -match 'href="https://example.invalid/enforce/watchlists/report/feedA-568483"' -and $html -notmatch '/report/568483"') 'Report link uses feed-local ID.'
        'PASS: canonical feed IDs, cross-source deduplication, distinct identities and unchanged raw responses'
    }
    $linkRows = @(
        [pscustomobject]@{ Name = '<script>test</script>'; Id = 'id/with?"&'; Source = '/api/original'; ReportTimestamp = '2026-09-01T00:00:00Z' },
        [pscustomobject]@{ Name = 'Earlier report'; Id = '98e85f88-e550-4dd4-be86-db9683d8496e'; Source = '/api/earlier'; ReportTimestamp = '2026-08-01T00:00:00Z' }
    )
    $originalRows = $linkRows | ConvertTo-Json
    $linkHtml = ConvertTo-ReportMetadataHtml -Rows $linkRows -BaseUrl 'https://defense-prod05.conferdeploy.net/'
    [xml]$linkTable = $linkHtml
    $anchors = @($linkTable.SelectNodes('/table/tr/td/a'))
    Assert-True ($anchors.Count -eq 2 -and $anchors[0].GetAttribute('href') -ceq 'https://defense-prod05.conferdeploy.net/enforce/watchlists/report/98e85f88-e550-4dd4-be86-db9683d8496e') 'Report URL or timestamp order incorrect.'
    Assert-True ($anchors[1].GetAttribute('href') -ceq 'https://defense-prod05.conferdeploy.net/enforce/watchlists/report/id%2Fwith%3F%22%26') 'Report ID not URL encoded.'
    Assert-True ($linkHtml -notmatch '<script>|/api/original|<th>Created</th>|<th>Updated</th>' -and $linkHtml -match 'View report') 'Report table escaping or columns incorrect.'
    Assert-True (($linkRows | ConvertTo-Json) -ceq $originalRows) 'HTML links mutated raw metadata.'
    [xml]$markedTable = ConvertTo-ReportMetadataHtml -Rows $linkRows -BaseUrl 'https://example.invalid' -RankedReports @([pscustomobject]@{ Name='Earlier report'; Alerts=42 })
    Assert-True ($markedTable.SelectNodes('//span[@class="top-report"]').Count -eq 1) 'Top 50 marker must only mark matching names.'
    Assert-True ($markedTable.SelectNodes('/table/tr[td]')[0].SelectNodes('td')[4].GetAttribute('data-sort-value') -eq '1') 'Top 50 sort value missing.'
    Assert-True ($markedTable.SelectSingleNode('//span[@class="top-report"]').GetAttribute('title') -match 'multiple report IDs') 'Marker attribution caveat missing.'
    Assert-True (($linkRows | ConvertTo-Json) -ceq $originalRows) 'Marker mutated raw metadata.'
    Assert-True ((ConvertTo-ReportMetadataHtml -Rows @() -BaseUrl 'https://example.invalid') -match 'No data returned') 'Empty metadata table failed.'
    $missingLink = ConvertTo-ReportMetadataHtml -Rows @([pscustomobject]@{ Name='Missing'; Id=''; Source='/api'; ReportTimestamp='' }) -BaseUrl 'https://example.invalid'
    Assert-True ($missingLink -match 'Report link unavailable' -and $missingLink -notmatch '<a ') 'Missing ID created invalid link.'
    $message = ''
    try { $null = ConvertTo-ReportMetadataHtml -Rows $linkRows -BaseUrl 'javascript:alert(1)' } catch { $message = $_.Exception.Message }
    Assert-True ($message -match 'HTTPS BaseUrl') 'Unsafe report URL scheme accepted.'
    'PASS: report links, encoding, ascending order, empty metadata and JSON preservation'
    foreach ($scenario in @('Normal', 'Empty', 'MetadataFailure', 'InvalidCount', 'MalformedFacet')) {
        Invoke-MockedWorkflow -Scenario $scenario
        "PASS: $scenario aggregate workflow"
    }
    'PASS: retention, filters, authentication/errors, full aggregate workflows, coverage, JSON/HTML and elapsed status. No network calls or output files.'
} $definitions $source