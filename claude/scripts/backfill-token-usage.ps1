param()
$ErrorActionPreference = 'Stop'

function Sum-UsageFromTranscript([string]$path) {
    $sum = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
    if (-not (Test-Path -LiteralPath $path)) { return $sum }
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '"usage"') { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry.type -ne 'assistant') { continue }
        $u = $entry.message.usage
        if (-not $u) { continue }
        if ($u.input_tokens)                { $sum.Input       += [int64]$u.input_tokens }
        if ($u.output_tokens)               { $sum.Output      += [int64]$u.output_tokens }
        if ($u.cache_read_input_tokens)     { $sum.CacheRead   += [int64]$u.cache_read_input_tokens }
        if ($u.cache_creation_input_tokens) { $sum.CacheCreate += [int64]$u.cache_creation_input_tokens }
    }
    return $sum
}

# Returns a hashtable: model name -> counters, one entry per distinct model
# string seen on assistant messages. Mirrors log-token-usage.ps1.
function Get-UsageByModel([string]$path) {
    $byModel = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $byModel }
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '"usage"') { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry.type -ne 'assistant') { continue }
        $u = $entry.message.usage
        if (-not $u) { continue }
        $model = if ($entry.message.model) { [string]$entry.message.model } else { 'unknown' }
        if (-not $byModel.ContainsKey($model)) {
            $byModel[$model] = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
        }
        $c = $byModel[$model]
        if ($u.input_tokens)                { $c.Input       += [int64]$u.input_tokens }
        if ($u.output_tokens)               { $c.Output      += [int64]$u.output_tokens }
        if ($u.cache_read_input_tokens)     { $c.CacheRead   += [int64]$u.cache_read_input_tokens }
        if ($u.cache_creation_input_tokens) { $c.CacheCreate += [int64]$u.cache_creation_input_tokens }
    }
    return $byModel
}

function Get-CwdFromTranscript([string]$path) {
    $i = 0
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        if ($i -ge 30) { break }
        $i++
        if ($line -notmatch '"cwd"') { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ($entry.cwd) { return [string]$entry.cwd }
    }
    return $null
}

$root = Join-Path $HOME '.claude\projects'
if (-not (Test-Path -LiteralPath $root)) { Write-Host 'No projects directory.'; exit 0 }

$logPath = Join-Path $HOME '.claude\token-usage.csv'
$header  = 'date,project,session_id,input,output,cache_read,cache_creation,subagent_total,total'

$modelPath   = Join-Path $HOME '.claude\token-usage-by-model.csv'
$modelHeader = 'date,project,session_id,scope,model,input,output,cache_read,cache_creation,total'

# Build map of existing session_id -> row so we don't duplicate. The live hook's
# row wins (we never overwrite) — backfill only fills holes.
$existingSessions = @{}
$existingRows = @()
if (Test-Path -LiteralPath $logPath) {
    $lines = Get-Content -LiteralPath $logPath
    if ($lines.Count -gt 0) {
        $startIdx = if ($lines[0] -like 'date,project,session_id,*') { 1 } else { 0 }
        for ($i = $startIdx; $i -lt $lines.Count; $i++) {
            $r = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            $cols = $r.Split(',')
            if ($cols.Length -ge 3) { $existingSessions[$cols[2]] = $true }
            $existingRows += $r
        }
    }
}

# Same idea for the per-model sidecar. Tracked independently: a session may be in
# the flat log (older live-hook row) yet missing from the sidecar, so we still
# backfill its model rows.
$existingModelSessions = @{}
$existingModelRows = @()
if (Test-Path -LiteralPath $modelPath) {
    $lines = Get-Content -LiteralPath $modelPath
    if ($lines.Count -gt 0) {
        $startIdx = if ($lines[0] -like 'date,project,session_id,scope,*') { 1 } else { 0 }
        for ($i = $startIdx; $i -lt $lines.Count; $i++) {
            $r = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            $cols = $r.Split(',')
            if ($cols.Length -ge 3) { $existingModelSessions[$cols[2]] = $true }
            $existingModelRows += $r
        }
    }
}
$modelNewRows = @()

$newRows = @()
$scanned = 0
$added   = 0
$skipped = 0

foreach ($projDir in Get-ChildItem -LiteralPath $root -Directory) {
    foreach ($f in Get-ChildItem -LiteralPath $projDir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
        $scanned++
        $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $needFlat  = -not $existingSessions.ContainsKey($sessionId)
        $needModel = -not $existingModelSessions.ContainsKey($sessionId)
        if (-not $needFlat -and -not $needModel) { $skipped++; continue }

        $cwd = Get-CwdFromTranscript $f.FullName
        $project = if ($cwd) { Split-Path -Path $cwd -Leaf } else { $projDir.Name }
        $date = $f.LastWriteTime.ToString('yyyy-MM-dd')
        $subDir = Join-Path $projDir.FullName (Join-Path $sessionId 'subagents')

        if ($needFlat) {
            $main = Sum-UsageFromTranscript $f.FullName

            $subSum = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
            if (Test-Path -LiteralPath $subDir) {
                Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $s = Sum-UsageFromTranscript $_.FullName
                    $subSum.Input       += $s.Input
                    $subSum.Output      += $s.Output
                    $subSum.CacheRead   += $s.CacheRead
                    $subSum.CacheCreate += $s.CacheCreate
                }
            }

            $inTok       = $main.Input       + $subSum.Input
            $outTok      = $main.Output      + $subSum.Output
            $cacheRead   = $main.CacheRead   + $subSum.CacheRead
            $cacheCreate = $main.CacheCreate + $subSum.CacheCreate
            $subTotal    = $subSum.Input + $subSum.Output + $subSum.CacheRead + $subSum.CacheCreate
            $total       = $inTok + $outTok + $cacheRead + $cacheCreate

            if ($total -gt 0) {
                $newRows += "$date,$project,$sessionId,$inTok,$outTok,$cacheRead,$cacheCreate,$subTotal,$total"
                $added++
            }
        }

        if ($needModel) {
            $mainModels = Get-UsageByModel $f.FullName
            $subModels  = @{}
            if (Test-Path -LiteralPath $subDir) {
                Get-ChildItem -LiteralPath $subDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $m = Get-UsageByModel $_.FullName
                    foreach ($k in $m.Keys) {
                        if (-not $subModels.ContainsKey($k)) {
                            $subModels[$k] = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
                        }
                        $subModels[$k].Input       += $m[$k].Input
                        $subModels[$k].Output      += $m[$k].Output
                        $subModels[$k].CacheRead   += $m[$k].CacheRead
                        $subModels[$k].CacheCreate += $m[$k].CacheCreate
                    }
                }
            }
            foreach ($scope in @('main', 'subagent')) {
                $src = if ($scope -eq 'main') { $mainModels } else { $subModels }
                foreach ($model in $src.Keys) {
                    $c = $src[$model]
                    $t = $c.Input + $c.Output + $c.CacheRead + $c.CacheCreate
                    if ($t -eq 0) { continue }
                    $modelNewRows += "$date,$project,$sessionId,$scope,$model,$($c.Input),$($c.Output),$($c.CacheRead),$($c.CacheCreate),$t"
                }
            }
        }
    }
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeTokenUsageLog')
[void]$mutex.WaitOne()
try {
    $allRows = @($header) + $existingRows + $newRows
    [System.IO.File]::WriteAllLines($logPath, $allRows, [System.Text.UTF8Encoding]::new($false))
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

$modelMutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeTokenUsageByModelLog')
[void]$modelMutex.WaitOne()
try {
    $allModelRows = @($modelHeader) + $existingModelRows + $modelNewRows
    [System.IO.File]::WriteAllLines($modelPath, $allModelRows, [System.Text.UTF8Encoding]::new($false))
} finally {
    $modelMutex.ReleaseMutex()
    $modelMutex.Dispose()
}

Write-Host "Scanned: $scanned"
Write-Host "Backfilled flat rows: $added"
Write-Host "Backfilled model rows: $($modelNewRows.Count)"
Write-Host "Skipped (already logged or empty): $skipped"
Write-Host "Log: $logPath"
Write-Host "Model log: $modelPath"
