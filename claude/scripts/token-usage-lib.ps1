# Shared library for Claude Code token usage reporting.
# Dot-sourced by token-summary.ps1 and token-dashboard.ps1 so pricing tables
# and CSV parsing live in exactly one place.

# Fallback pricing preset for sessions with NO per-model data (pre-June
# sessions whose transcripts are gone). Sessions WITH model data are always
# priced per model via Get-ModelRates.
function Get-PricingPreset([string]$Pricing) {
    switch ($Pricing) {
        'opus' {
            return @{
                Label        = 'Claude Opus 4.5+ standard (<=200K input)'
                Input        = 5.00
                Output       = 25.00
                CacheWrite5m = 6.25
                CacheWrite1h = 10.00
                CacheRead    = 0.50
            }
        }
        'opus-4-launch' {
            return @{
                Label        = 'Claude Opus 4.0 launch (<=200K input)'
                Input        = 15.00
                Output       = 75.00
                CacheWrite5m = 18.75
                CacheWrite1h = 30.00
                CacheRead    = 1.50
            }
        }
        'sonnet' {
            return @{
                Label        = 'Claude Sonnet 4 standard (<=200K input)'
                Input        = 3.00
                Output       = 15.00
                CacheWrite5m = 3.75
                CacheWrite1h = 6.00
                CacheRead    = 0.30
            }
        }
        default { throw "Unknown pricing preset: $Pricing" }
    }
}

# Per-model rates by family. Cache-write 5m = 1.25x input, 1h = 2x input,
# cache-read = 0.1x input. Families collapse to a single rate because every
# version within a family is priced identically (opus-4-7 == opus-4-8, etc.).
# Unknown / missing model strings fall back to Opus.
function Get-ModelRates([string]$model) {
    $m = if ($model) { $model.ToLower() } else { '' }
    if ($m -eq '<synthetic>' -or $m -eq 'synthetic') {
        return @{ Input = 0; Output = 0; CacheWrite5m = 0; CacheWrite1h = 0; CacheRead = 0 }
    }
    if ($m -like '*fable*' -or $m -like '*mythos*') {
        return @{ Input = 10.00; Output = 50.00; CacheWrite5m = 12.50; CacheWrite1h = 20.00; CacheRead = 1.00 }
    }
    if ($m -like '*haiku*') {
        return @{ Input = 1.00; Output = 5.00; CacheWrite5m = 1.25; CacheWrite1h = 2.00; CacheRead = 0.10 }
    }
    if ($m -like '*sonnet*') {
        return @{ Input = 3.00; Output = 15.00; CacheWrite5m = 3.75; CacheWrite1h = 6.00; CacheRead = 0.30 }
    }
    # opus and everything unrecognized -> Opus rates
    return @{ Input = 5.00; Output = 25.00; CacheWrite5m = 6.25; CacheWrite1h = 10.00; CacheRead = 0.50 }
}

function Import-TokenUsageRows([string]$logPath) {
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }
    $rows = @(Import-Csv -LiteralPath $logPath)
    foreach ($r in $rows) {
        $r.input          = [int64]$r.input
        $r.output         = [int64]$r.output
        $r.cache_read     = [int64]$r.cache_read
        $r.cache_creation = [int64]$r.cache_creation
        $r.subagent_total = [int64]$r.subagent_total
        $r.total          = [int64]$r.total
    }
    return $rows
}

# Returns a hashtable: session_id -> ArrayList of per-model rows.
function Import-TokenUsageByModel([string]$modelLogPath) {
    $sessionModelMap = @{}
    if (-not (Test-Path -LiteralPath $modelLogPath)) { return $sessionModelMap }
    foreach ($mr in Import-Csv -LiteralPath $modelLogPath) {
        $mr.input          = [int64]$mr.input
        $mr.output         = [int64]$mr.output
        $mr.cache_read     = [int64]$mr.cache_read
        $mr.cache_creation = [int64]$mr.cache_creation
        $mr.total          = [int64]$mr.total
        if (-not $sessionModelMap.ContainsKey($mr.session_id)) {
            $sessionModelMap[$mr.session_id] = New-Object System.Collections.ArrayList
        }
        [void]$sessionModelMap[$mr.session_id].Add($mr)
    }
    return $sessionModelMap
}

# Cost parts ($ per category) for one flat session row. Uses per-model rates
# when the session has sidecar data; otherwise prices the flat totals at the
# fallback preset ($rates).
function Get-SessionCostParts($row, $sessionModelMap, $rates) {
    $parts = [pscustomobject]@{ In = 0.0; Out = 0.0; Cw5m = 0.0; Cw1h = 0.0; Cr = 0.0; HasModel = $false }
    if ($sessionModelMap.ContainsKey($row.session_id)) {
        $parts.HasModel = $true
        foreach ($mr in $sessionModelMap[$row.session_id]) {
            $rt = Get-ModelRates $mr.model
            $parts.In   += $mr.input          * $rt.Input        / 1e6
            $parts.Out  += $mr.output         * $rt.Output       / 1e6
            $parts.Cw5m += $mr.cache_creation * $rt.CacheWrite5m / 1e6
            $parts.Cw1h += $mr.cache_creation * $rt.CacheWrite1h / 1e6
            $parts.Cr   += $mr.cache_read     * $rt.CacheRead    / 1e6
        }
    } else {
        $parts.In   = $row.input          * $rates.Input        / 1e6
        $parts.Out  = $row.output         * $rates.Output       / 1e6
        $parts.Cw5m = $row.cache_creation * $rates.CacheWrite5m / 1e6
        $parts.Cw1h = $row.cache_creation * $rates.CacheWrite1h / 1e6
        $parts.Cr   = $row.cache_read     * $rates.CacheRead    / 1e6
    }
    return $parts
}

function Get-SessionCost5m($row, $sessionModelMap, $rates) {
    $p = Get-SessionCostParts $row $sessionModelMap $rates
    return $p.In + $p.Out + $p.Cw5m + $p.Cr
}

function Get-SessionCostHigh($row, $sessionModelMap, $rates) {
    $p = Get-SessionCostParts $row $sessionModelMap $rates
    return $p.In + $p.Out + $p.Cw1h + $p.Cr
}
