[CmdletBinding()]
param(
    [int]$Days = 7,
    [string]$Project,
    [int]$TopSessions = 0,
    # Fallback pricing preset for sessions with NO per-model data (pre-June
    # sessions whose transcripts are gone). Defaults to Opus, the model used in
    # ~90% of sessions. Sessions WITH model data are always priced per model.
    [ValidateSet('opus','opus-4-launch','sonnet')]
    [string]$Pricing = 'opus'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'token-usage-lib.ps1')

# Anthropic API published rates ($ per 1M tokens). If you're on a Pro/Max
# subscription these are informational; if billed per-token they estimate cost.
$rates = Get-PricingPreset $Pricing

$logPath = Join-Path $HOME '.claude\token-usage.csv'
if (-not (Test-Path -LiteralPath $logPath)) {
    Write-Host "No token log found at $logPath. Run a session (or backfill-token-usage.ps1) first."
    exit 0
}

$rows = Import-TokenUsageRows $logPath
if ($rows.Count -eq 0) { Write-Host 'Token log is empty.'; exit 0 }

$today    = (Get-Date).Date
$cutoff   = $today.AddDays(-($Days - 1))
$filtered = $rows | Where-Object {
    $d = [datetime]::ParseExact($_.date, 'yyyy-MM-dd', $null)
    $d -ge $cutoff -and $d -le $today
}
if ($Project) { $filtered = $filtered | Where-Object { $_.project -eq $Project } }

# Per-model sidecar (token-usage-by-model.csv): session_id -> list of model rows.
$modelLogPath = Join-Path $HOME '.claude\token-usage-by-model.csv'
$sessionModelMap = Import-TokenUsageByModel $modelLogPath

$rangeLabel = "$($cutoff.ToString('yyyy-MM-dd')) to $($today.ToString('yyyy-MM-dd'))"
$projLabel  = if ($Project) { "  project=$Project" } else { '' }

Write-Host ''
Write-Host "Token usage - last $Days day(s)  ($rangeLabel)$projLabel"
Write-Host ('=' * 72)

if (-not $filtered -or @($filtered).Count -eq 0) { Write-Host 'No sessions in window.'; exit 0 }

$total       = ($filtered | Measure-Object total          -Sum).Sum
$subTotal    = ($filtered | Measure-Object subagent_total -Sum).Sum
$cacheRead   = ($filtered | Measure-Object cache_read     -Sum).Sum
$cacheCreate = ($filtered | Measure-Object cache_creation -Sum).Sum
$inTok       = ($filtered | Measure-Object input          -Sum).Sum
$outTok      = ($filtered | Measure-Object output         -Sum).Sum
$sessions    = @($filtered).Count
$subPct      = if ($total -gt 0) { [math]::Round(100 * $subTotal / $total, 1) } else { 0 }
$cacheHitPct = if (($cacheRead + $cacheCreate) -gt 0) { [math]::Round(100 * $cacheRead / ($cacheRead + $cacheCreate), 1) } else { 0 }

Write-Host ''
Write-Host 'RAW TOKEN ACTIVITY'
Write-Host ('-' * 72)
Write-Host ("  Total          {0,18:N0}   ({1} sessions)" -f $total, $sessions)
Write-Host ("    input        {0,18:N0}" -f $inTok)
Write-Host ("    output       {0,18:N0}" -f $outTok)
Write-Host ("    cache read   {0,18:N0}   <- re-reads of cached prompt prefix" -f $cacheRead)
Write-Host ("    cache write  {0,18:N0}   <- new cache entries" -f $cacheCreate)
Write-Host ("  Subagents      {0,18:N0}   ({1}% of total)" -f $subTotal, $subPct)
Write-Host ("  Cache hit      {0,17}%   (read / (read+write); higher = better reuse)" -f $cacheHitPct)

# Model-aware cost: sum per-session parts (per-model where available).
$inCost = 0.0; $outCost = 0.0; $cwCost5m = 0.0; $cwCost1h = 0.0; $crCost = 0.0
$withModel = 0; $withoutModel = 0
foreach ($row in $filtered) {
    $p = Get-SessionCostParts $row $sessionModelMap $rates
    $inCost   += $p.In
    $outCost  += $p.Out
    $cwCost5m += $p.Cw5m
    $cwCost1h += $p.Cw1h
    $crCost   += $p.Cr
    if ($p.HasModel) { $withModel++ } else { $withoutModel++ }
}
$totalLow  = $inCost + $outCost + $cwCost5m + $crCost
$totalHigh = $inCost + $outCost + $cwCost1h + $crCost

Write-Host ''
Write-Host "ESTIMATED API COST  (per-model where available; $($rates.Label) for the rest)"
Write-Host ('-' * 72)
Write-Host ("  input                          `${0,12:N2}" -f $inCost)
Write-Host ("  output                         `${0,12:N2}" -f $outCost)
Write-Host ("  cache write (5m TTL)           `${0,12:N2}   to  `${1,12:N2} (1h TTL)" -f $cwCost5m, $cwCost1h)
Write-Host ("  cache read                     `${0,12:N2}" -f $crCost)
Write-Host ('  ' + ('-' * 70))
Write-Host ("  Estimated cost                 `${0,12:N2}   to  `${1,12:N2}" -f $totalLow, $totalHigh)
Write-Host ''
Write-Host ("  Sessions priced per-model: {0} / {1}   (remaining {2} assumed {3})" -f $withModel, $sessions, $withoutModel, $Pricing)
Write-Host "  (If you're on a Pro/Max subscription, this is informational only - not your bill.)"
Write-Host "  (Range reflects unknown 5m vs 1h cache-write TTL. 1M-context tier > 200K input is priced higher.)"

# BY MODEL - aggregate model rows across filtered sessions, plus a bucket for
# filtered sessions with no model data (priced at the fallback preset).
Write-Host ''
Write-Host 'BY MODEL'
Write-Host ('-' * 72)
Write-Host ('  {0,-34} {1,15} {2,11} {3,5}' -f 'Model', 'Tokens', 'Est. $ (5m)', 'Sub%')

$modelAgg = @{}
function Add-ModelAgg($name, $tokens, $subTokens, $cost) {
    if (-not $modelAgg.ContainsKey($name)) {
        $modelAgg[$name] = [pscustomobject]@{ Tokens = 0L; Sub = 0L; Cost = 0.0 }
    }
    $modelAgg[$name].Tokens += [int64]$tokens
    $modelAgg[$name].Sub    += [int64]$subTokens
    $modelAgg[$name].Cost   += [double]$cost
}

foreach ($row in $filtered) {
    if ($sessionModelMap.ContainsKey($row.session_id)) {
        foreach ($mr in $sessionModelMap[$row.session_id]) {
            $rt   = Get-ModelRates $mr.model
            $cost = ($mr.input * $rt.Input + $mr.output * $rt.Output + $mr.cache_creation * $rt.CacheWrite5m + $mr.cache_read * $rt.CacheRead) / 1e6
            $sub  = if ($mr.scope -eq 'subagent') { $mr.total } else { 0 }
            Add-ModelAgg $mr.model $mr.total $sub $cost
        }
    } else {
        $cost = Get-SessionCost5m $row $sessionModelMap $rates
        Add-ModelAgg "(no model data - $Pricing)" $row.total $row.subagent_total $cost
    }
}

$modelAgg.GetEnumerator() |
    Sort-Object { $_.Value.Tokens } -Descending |
    ForEach-Object {
        $sp = if ($_.Value.Tokens -gt 0) { [math]::Round(100 * $_.Value.Sub / $_.Value.Tokens, 1) } else { 0 }
        Write-Host ('  {0,-34} {1,15:N0} {2,11} {3,4}%' -f $_.Key, $_.Value.Tokens, ('${0:N2}' -f $_.Value.Cost), $sp)
    }

if (-not $Project) {
    Write-Host ''
    Write-Host 'BY PROJECT'
    Write-Host ('-' * 72)
    Write-Host ('  {0,-40} {1,15} {2,11} {3,5} {4,5}' -f 'Project', 'Tokens', 'Est. $ (5m)', 'Sess', 'Sub%')
    $filtered |
        Group-Object project |
        Sort-Object { ($_.Group | Measure-Object total -Sum).Sum } -Descending |
        ForEach-Object {
            $g    = $_.Group
            $t    = ($g | Measure-Object total          -Sum).Sum
            $s    = ($g | Measure-Object subagent_total -Sum).Sum
            $sp   = if ($t -gt 0) { [math]::Round(100 * $s / $t, 1) } else { 0 }
            $sess = @($g).Count
            $cost = ($g | ForEach-Object { Get-SessionCost5m $_ $sessionModelMap $rates } | Measure-Object -Sum).Sum
            Write-Host ('  {0,-40} {1,15:N0} {2,11} {3,5} {4,4}%' -f $_.Name, $t, ('${0:N2}' -f $cost), $sess, $sp)
        }
}

Write-Host ''
Write-Host 'BY DAY'
Write-Host ('-' * 72)
$byDay = @{}
$filtered | Group-Object date | ForEach-Object {
    $byDay[$_.Name] = [pscustomobject]@{
        Sessions = @($_.Group).Count
        Total    = ($_.Group | Measure-Object total -Sum).Sum
        Cost     = ($_.Group | ForEach-Object { Get-SessionCost5m $_ $sessionModelMap $rates } | Measure-Object -Sum).Sum
    }
}
for ($i = 0; $i -lt $Days; $i++) {
    $d = $today.AddDays(-$i).ToString('yyyy-MM-dd')
    if ($byDay.ContainsKey($d)) {
        Write-Host ('  {0}   {1,15:N0}   {2,10}   ({3} sessions)' -f $d, $byDay[$d].Total, ('${0:N2}' -f $byDay[$d].Cost), $byDay[$d].Sessions)
    } else {
        Write-Host ('  {0}   {1,15}   {2,10}   (0 sessions)' -f $d, '-', '-')
    }
}

if ($TopSessions -gt 0) {
    Write-Host ''
    Write-Host "TOP $TopSessions SESSIONS BY TOKENS"
    Write-Host ('-' * 72)
    $filtered |
        Sort-Object total -Descending |
        Select-Object -First $TopSessions |
        ForEach-Object {
            $sp   = if ($_.total -gt 0) { [math]::Round(100 * $_.subagent_total / $_.total, 1) } else { 0 }
            $cost = Get-SessionCost5m $_ $sessionModelMap $rates
            Write-Host ('  {0}  {1,-40} {2,15:N0}  {3,9}  (sub={4}%)' -f $_.date, $_.project, $_.total, ('${0:N2}' -f $cost), $sp)
        }
}

Write-Host ''
