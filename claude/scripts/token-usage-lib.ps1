# Shared library for Claude Code token usage reporting.
# Dot-sourced by the token scripts so the config dir, pricing tables and CSV
# parsing live in exactly one place.

# Same resolution Claude Code uses, so a CLAUDE_CONFIG_DIR install reads and
# writes its own tree instead of ~/.claude.
function Get-ClaudeConfigDir {
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $HOME '.claude')
}

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

# Per-model-version rates in $/MTok, from https://platform.claude.com/docs/en/about-claude/pricing
# (checked 2026-09-23). Prices differ between versions of the same family, so
# this table has to be updated by hand whenever Anthropic changes them.
# Cache-write 5m = 1.25x input and 1h = 2x input everywhere; cache-read is
# 0.1x input except on fable/mythos 5.1 and opus 5.5, which are cheaper.
# Within a family, rules are ordered newest first and the first rule whose
# MinVersion is <= the model's version wins.
$script:ModelRateRules = @(
    @{ Family = 'fable';  MinVersion = [version]'5.1'; Rates = @{ Input = 10.00; Output = 50.00; CacheWrite5m = 12.50; CacheWrite1h = 20.00; CacheRead = 0.25 } }
    @{ Family = 'fable';  MinVersion = [version]'0.0'; Rates = @{ Input = 10.00; Output = 50.00; CacheWrite5m = 12.50; CacheWrite1h = 20.00; CacheRead = 1.00 } }
    @{ Family = 'mythos'; MinVersion = [version]'5.1'; Rates = @{ Input = 10.00; Output = 50.00; CacheWrite5m = 12.50; CacheWrite1h = 20.00; CacheRead = 0.25 } }
    @{ Family = 'mythos'; MinVersion = [version]'0.0'; Rates = @{ Input = 10.00; Output = 50.00; CacheWrite5m = 12.50; CacheWrite1h = 20.00; CacheRead = 1.00 } }
    @{ Family = 'opus';   MinVersion = [version]'5.5'; Rates = @{ Input =  4.00; Output = 20.00; CacheWrite5m =  5.00; CacheWrite1h =  8.00; CacheRead = 0.20 } }
    @{ Family = 'opus';   MinVersion = [version]'4.5'; Rates = @{ Input =  5.00; Output = 25.00; CacheWrite5m =  6.25; CacheWrite1h = 10.00; CacheRead = 0.50 } }
    @{ Family = 'opus';   MinVersion = [version]'0.0'; Rates = @{ Input = 15.00; Output = 75.00; CacheWrite5m = 18.75; CacheWrite1h = 30.00; CacheRead = 1.50 } }
    @{ Family = 'sonnet'; MinVersion = [version]'5.0'; Rates = @{ Input =  2.00; Output = 10.00; CacheWrite5m =  2.50; CacheWrite1h =  4.00; CacheRead = 0.20 } }
    @{ Family = 'sonnet'; MinVersion = [version]'0.0'; Rates = @{ Input =  3.00; Output = 15.00; CacheWrite5m =  3.75; CacheWrite1h =  6.00; CacheRead = 0.30 } }
    @{ Family = 'haiku';  MinVersion = [version]'0.0'; Rates = @{ Input =  1.00; Output =  5.00; CacheWrite5m =  1.25; CacheWrite1h =  2.00; CacheRead = 0.10 } }
)

# Unknown / missing model strings fall back to the Opus 4.5+ rate.
function Get-ModelRates([string]$model) {
    $m = if ($model) { $model.ToLower() } else { '' }
    if ($m -eq '<synthetic>' -or $m -eq 'synthetic') {
        return @{ Input = 0; Output = 0; CacheWrite5m = 0; CacheWrite1h = 0; CacheRead = 0 }
    }
    $families = 'fable|mythos|opus|sonnet|haiku'
    # Versions are capped at two digits so a trailing date (claude-sonnet-4-20250514,
    # claude-3-7-sonnet-20250219) is never read as one. The second pattern is the
    # older claude-3-5-haiku naming.
    if ($m -match "(?<family>$families)-(?<major>\d{1,2})(?:-(?<minor>\d{1,2}))?(?!\d)" -or
        $m -match "claude-(?<major>\d{1,2})(?:-(?<minor>\d{1,2}))?-(?<family>$families)") {
        $minor = if ($Matches['minor']) { $Matches['minor'] } else { '0' }
        $version = [version]"$($Matches['major']).$minor"
        foreach ($rule in $script:ModelRateRules) {
            if ($rule.Family -eq $Matches['family'] -and $version -ge $rule.MinVersion) {
                return $rule.Rates.Clone()
            }
        }
    }
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
