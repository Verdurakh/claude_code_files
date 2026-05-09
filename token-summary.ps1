[CmdletBinding()]
param(
    [int]$Days = 7,
    [string]$Project,
    [int]$TopSessions = 0,
    # Pricing preset. "opus" = Claude Opus 4 standard (<=200K input). "sonnet" = Claude Sonnet 4 standard.
    [ValidateSet('opus','sonnet')]
    [string]$Pricing = 'opus'
)

$ErrorActionPreference = 'Stop'

# Anthropic API published rates ($ per 1M tokens). Used to estimate what usage
# would cost on per-token API billing. If you're on a Pro/Max subscription this
# is informational only; if you're billed per-token via the API it's a rough
# estimate of your actual cost.
$rates = switch ($Pricing) {
    'opus' {
        @{
            Label        = 'Claude Opus 4 standard (<=200K input)'
            Input        = 15.00
            Output       = 75.00
            CacheWrite5m = 18.75
            CacheWrite1h = 30.00
            CacheRead    = 1.50
        }
    }
    'sonnet' {
        @{
            Label        = 'Claude Sonnet 4 standard (<=200K input)'
            Input        = 3.00
            Output       = 15.00
            CacheWrite5m = 3.75
            CacheWrite1h = 6.00
            CacheRead    = 0.30
        }
    }
}

function Get-Cost {
    param($Row, $CacheWriteRate)
    $c = 0.0
    $c += [double]$Row.input          * $rates.Input        / 1e6
    $c += [double]$Row.output         * $rates.Output       / 1e6
    $c += [double]$Row.cache_creation * $CacheWriteRate     / 1e6
    $c += [double]$Row.cache_read     * $rates.CacheRead    / 1e6
    return $c
}

$logPath = Join-Path $HOME '.claude\token-usage.csv'
if (-not (Test-Path -LiteralPath $logPath)) {
    Write-Host "No token log found at $logPath. Run a session (or backfill-token-usage.ps1) first."
    exit 0
}

$rows = Import-Csv -LiteralPath $logPath
if ($rows.Count -eq 0) { Write-Host 'Token log is empty.'; exit 0 }

foreach ($r in $rows) {
    $r.input          = [int64]$r.input
    $r.output         = [int64]$r.output
    $r.cache_read     = [int64]$r.cache_read
    $r.cache_creation = [int64]$r.cache_creation
    $r.subagent_total = [int64]$r.subagent_total
    $r.total          = [int64]$r.total
}

$today    = (Get-Date).Date
$cutoff   = $today.AddDays(-($Days - 1))
$filtered = $rows | Where-Object {
    $d = [datetime]::ParseExact($_.date, 'yyyy-MM-dd', $null)
    $d -ge $cutoff -and $d -le $today
}
if ($Project) { $filtered = $filtered | Where-Object { $_.project -eq $Project } }

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

# Cost breakdown - show as a range because cache writes can be 5m or 1h TTL
$inCost      = $inTok       * $rates.Input        / 1e6
$outCost     = $outTok      * $rates.Output       / 1e6
$cwCost5m    = $cacheCreate * $rates.CacheWrite5m / 1e6
$cwCost1h    = $cacheCreate * $rates.CacheWrite1h / 1e6
$crCost      = $cacheRead   * $rates.CacheRead    / 1e6
$totalLow    = $inCost + $outCost + $cwCost5m + $crCost
$totalHigh   = $inCost + $outCost + $cwCost1h + $crCost

Write-Host ''
Write-Host "ESTIMATED API COST  (preset: $($rates.Label))"
Write-Host ('-' * 72)
Write-Host ("  input         @  `${0,6:N2}/M       `${1,12:N2}" -f $rates.Input, $inCost)
Write-Host ("  output        @  `${0,6:N2}/M       `${1,12:N2}" -f $rates.Output, $outCost)
Write-Host ("  cache write   @  `${0,6:N2}/M (5m)  `${1,12:N2}   to  `${2,12:N2} (`$ {3:N2}/M @ 1h TTL)" -f $rates.CacheWrite5m, $cwCost5m, $cwCost1h, $rates.CacheWrite1h)
Write-Host ("  cache read    @  `${0,6:N2}/M       `${1,12:N2}" -f $rates.CacheRead, $crCost)
Write-Host ('  ' + ('-' * 70))
Write-Host ("  Estimated cost                    `${0,12:N2}   to  `${1,12:N2}" -f $totalLow, $totalHigh)
Write-Host ''
Write-Host "  (If you're on a Pro/Max subscription, this is informational only - not your bill.)"
Write-Host "  (Range reflects unknown 5m vs 1h cache-write TTL. 1M-context tier > 200K input is priced higher.)"

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
            $cost = ($g | ForEach-Object { Get-Cost -Row $_ -CacheWriteRate $rates.CacheWrite5m } | Measure-Object -Sum).Sum
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
        Cost     = ($_.Group | ForEach-Object { Get-Cost -Row $_ -CacheWriteRate $rates.CacheWrite5m } | Measure-Object -Sum).Sum
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
            $cost = Get-Cost -Row $_ -CacheWriteRate $rates.CacheWrite5m
            Write-Host ('  {0}  {1,-40} {2,15:N0}  {3,9}  (sub={4}%)' -f $_.date, $_.project, $_.total, ('${0:N2}' -f $cost), $sp)
        }
}

Write-Host ''
