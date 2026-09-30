# Watchlist Analytics

PowerShell analytics for Carbon Black Cloud watchlist alerts. The script uses
server-side counts and facets rather than downloading individual alerts. It
produces a standalone HTML report and JSON containing the underlying aggregation
and metadata responses.

The script is read-only: it does not edit, disable, or delete watchlists or reports.

## Requirements

- Windows PowerShell 5.1. The offline regression suite has been exercised in this environment.
- Network access to your Carbon Black Cloud tenant's HTTPS endpoint.
- Enterprise EDR for watchlist/report metadata.
- A Custom API key with these read permissions:

| Permission | Purpose |
| --- | --- |
| `org.alerts` / READ | Alert counts, facets, and histogram |
| `org.watchlists` / READ | Watchlists and custom report metadata |
| `org.feeds` / READ | Subscribed feed report metadata |

No additional PowerShell modules are required. Metadata access failures are
recorded as warnings; failures fetching required alert aggregations stop the run.

## Setup

Use [WatchlistAnalytics.config.json](WatchlistAnalytics.config.json) as the
configuration template. To create a local config without overwriting an existing one:

```powershell
if (-not (Test-Path -LiteralPath '.\cb-creds.json')) {
    Copy-Item -LiteralPath '.\WatchlistAnalytics.config.json' -Destination '.\cb-creds.json'
}
```

Set `BaseUrl` to your tenant's actual regional console URL, and populate `OrgKey`
and `ApiId`. Do not leave the template placeholders in place. Use HTTPS.

The config stores the **name** of the environment variable containing the API
secret, not the secret itself. `ApiSecretEnvironmentVariable` defaults to
`CBC_API_SECRET`. Set it in the same terminal that will run the script:

```powershell
$secureSecret = Read-Host 'Carbon Black API secret' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
try {
    $env:CBC_API_SECRET = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    $secureSecret.Dispose()
}
```

The prompt avoids putting the secret in command history. The environment variable
still holds plaintext accessible to the process and its child processes. Remove
it when finished:

```powershell
Remove-Item Env:CBC_API_SECRET -ErrorAction SilentlyContinue
```

Do not commit tenant config files or generated reports. Outputs can contain
endpoint names, usernames, detection details, and other sensitive tenant data.

## Usage

Run from this directory:

```powershell
.\WatchlistAnalytics.ps1 `
    -Config '.\cb-creds.json' `
    -StartDate '2026-08-01' `
    -EndDate '2026-09-01' `
    -OutputDirectory '.\output'
```

For the default last-seven-days window:

```powershell
.\WatchlistAnalytics.ps1 -Config '.\cb-creds.json'
```

| Parameter | Behavior |
| --- | --- |
| `-ConfigPath`, alias `-Config` | JSON config path. Defaults to `cb-creds.json` beside the script when present, otherwise the template. |
| `-StartDate` | Defaults to seven days before the current time, independently of a supplied end date. |
| `-EndDate` | Defaults to the current time. |
| `-OutputDirectory` | Defaults to the script directory; created if needed. |
| `-Verbose` | Displays HTTP methods and request URLs. |

Date-only arguments mean midnight in the local time zone, not the end of that
day. Requests and output dates are converted to UTC. To include all of September
30, for example, specify October 1 as the end date, or use `(Get-Date)` for data
available so far today.

Timestamped INFO messages identify the current phase and completed API calls.
Request durations and total elapsed time are printed. A synchronous request does
not emit a repeating heartbeat while waiting for its response.

### Retention

The script assumes 180-day alert retention. Older start dates are moved to
`now - 180 days + 5 minutes`, with an INFO message showing the adjustment. The
buffer avoids querying exactly at the moving retention boundary.

A valid end date is preserved. An entirely expired window resets to the retained
window ending now; future end dates are clamped to now. Reversed, empty, and
entirely future windows remain errors. The output records the effective dates.
This cannot recover expired alerts or override a tenant with shorter retention.

## Configuration

Keep the supplied API paths unless your deployment requires different ones.

| Setting | Meaning |
| --- | --- |
| `AlertSearch.BodyTemplate` | Optional `query`, `criteria`, and `exclusions` shared by counts and aggregations. The script supplies `time_range`. |
| `Analytics.FacetRows` | Top values requested per field; defaults to 50. Larger positive values are clamped to the API maximum of 50 with INFO output. |
| `Recommendation.HighAlertThreshold` | Count at which a report-name group is prioritized for tuning review; defaults to 100000 over the requested window. |
| `Paths.Watchlists` | Watchlist inventory endpoint. |
| `Paths.Report` | Individual report metadata endpoint using `{reportId}`. |
| `Paths.FeedReports` | Feed reports endpoint using `{feedId}`. |

Rankings and histogram use `type: WATCHLIST` in addition to your configured
filters. Explicit `criteria.type` values must include `WATCHLIST`. The all-type
count retains the original filters, so a configured type restriction also narrows
that denominator. Match dates, severity, workflow, and other filters when comparing
results with the Carbon Black console.

Older configs still work. `SliceHours`, `MinimumSliceMinutes`, `RowsPerRequest`,
`TimeField`, `TotalField`, `Fields`, `StaleDays`, and `Paths.Reports` are no longer
used. The original watchlist path without `/threathunter` is corrected in memory.

## Outputs

Each run writes `watchlist-analytics.html` and `watchlist-analytics.json` in the
output directory. Existing files with those names are overwritten; use separate
output directories to preserve runs.

### HTML

Open the generated HTML directly in a browser; no web server is needed. It contains:

- All-type and WATCHLIST alert totals under the configured filters.
- Top report names, endpoint names, and process users, with percentages.
- Current watchlist metadata.
- Current report metadata, sorted by `ReportTimestamp` ascending.
- Warnings about coverage, attribution, and unavailable metadata.

The report metadata table omits Created/Updated and provides a **View report**
link in Source. Links use the tenant hostname and fully qualified report ID;
opening them requires Carbon Black console access. Feed-local IDs are qualified
with the feed ID and duplicates are merged by full ID, not by report name.

Daily watchlist alerts and Ranking coverage are not displayed as HTML sections.
Their data remains in JSON.

All table headers are clickable sort buttons. Click again to reverse the order;
keyboard users can activate them with Enter or Space. Counts and percentages sort
numerically, dates chronologically, and unavailable dates stay at the bottom.
Report metadata initially remains sorted by ReportTimestamp ascending.

Report metadata includes a Top 50 star marker when its name matches a positive-count
entry in the returned top report-name ranking (up to 50 values). The tooltip notes
that one name can represent multiple report IDs, so multiple metadata rows may
share the marker. If `Analytics.FacetRows` is below 50, only that smaller returned
set is marked. Unmarked reports do not imply zero alerts. Markers and sorting are
HTML-only; no per-report count requests are added and JSON is unchanged.

### JSON

Schema version 2 stores normalized analytics alongside the underlying API data:

- `TotalAlerts`, `WatchlistAlerts`, `Reports`, `Endpoints`, and `Users`.
- `DailyAlerts`, `Coverage`, and `Warnings`.
- `Watchlists` and `ReportMetadata`.
- `Raw.Aggregations`: count, facet, and histogram requests and responses.
- `Raw.Metadata`: metadata response records, source paths, and recorded failures.

There is no individual `Alerts` array. Raw metadata preserves the original API
IDs and source data; normalized report metadata uses qualified IDs.

Once aggregation collection completes, the script writes a JSON checkpoint before
fetching metadata. Its `Status` says that metadata and the report are pending.
Successful processing replaces it with the final JSON. A pending checkpoint is
not a complete report or an automatic resume mechanism. After a failed run, an
HTML file left from an earlier run may be stale.

## Interpretation and Performance

Facet rankings contain **top returned values**, not a complete inventory. Reaching
the requested cap produces a warning; omitted values must not be treated as zero.
Report names can combine multiple report IDs, and device names can combine
multiple devices. Missing or multi-valued fields mean percentages need not sum
to 100. Counts come from separate API snapshots, not a transaction.

`PercentOfWatchlistAlerts` uses the filtered WATCHLIST total.
`PercentOfAllAlerts` uses the original filtered all-type total, not the sum of
displayed facet rows.

The report timestamp is publisher-supplied metadata, not a verified creation or
update date. Unavailable dates are marked explicitly. Current report metadata may
not match historical alert names, so metadata and rankings remain separate tables.

Recommendations are review priorities only. High volume alone does not establish
false positives, and low volume does not make a detection unnecessary. Validate
whether a report is benign, redundant, or no longer required before disabling it.

The usual request count is:

- Four alert aggregation calls: two counts, one combined facet call, one histogram.
- One watchlist inventory call.
- One call per unique report metadata path referenced by custom watchlists.
- One call per unique subscribed feed to retrieve its reports.

Zero WATCHLIST alerts skip facets and histogram. Calls run sequentially; runtime
depends on API latency, server-side query work, and the number of metadata
requests, not hourly windows or downloaded alert volume. Metadata is not cached
between runs. The script does not currently retry throttled or transient failures.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Scripts are disabled | If organizational policy permits, use `Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned` in the running terminal. Do not override enforced policy. |
| API secret missing | Set the named environment variable in the same terminal running the script. Other terminals can have different environments. |
| HTTP 401 / 403 | Verify the regional hostname, org key, matching API ID/secret, and read permissions. Authentication uses `ApiSecret/ApiId`. |
| Facet rows exceed 50 | The current script clamps larger values; verify you are running the updated script. |
| Retention error | Check the effective dates and actual tenant retention. The automatic clamp assumes 180 days. |
| Metadata unavailable | Check watchlist/feed read access and the warning's endpoint. Aggregate rankings can still be produced. |
| Totals differ from the console | Compare the effective UTC dates and all active filters. A date-only end excludes most of that calendar day. |
| HTTP 429 or transient server error | Wait as directed by the service and rerun; automatic retry is not implemented. |

## Tests

```powershell
.\WatchlistAnalytics.Tests.ps1
```

Tests use mocked API calls and output sinks; no tenant credentials, network
requests, or generated report files are required. They cover retention, filters,
facet limits, authentication/error handling, aggregate workflows, metadata identity,
report links, JSON preservation, and HTML rendering. They do not replace live API
validation.

## References

- [Design notes](design.md)
- [Alerts v7 API](https://developer.carbonblack.com/reference/carbon-black-cloud/platform/latest/alerts-api/)
- [Alert search and facet fields](https://developer.carbonblack.com/reference/carbon-black-cloud/platform/latest/alert-search-fields/)
- [Watchlist API](https://developer.carbonblack.com/reference/carbon-black-cloud/cb-threathunter/latest/watchlist-api/)
- [Feed Manager API](https://developer.carbonblack.com/reference/carbon-black-cloud/cb-threathunter/latest/feed-api/)