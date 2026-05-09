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

$newRows = @()
$scanned = 0
$added   = 0
$skipped = 0

foreach ($projDir in Get-ChildItem -LiteralPath $root -Directory) {
    foreach ($f in Get-ChildItem -LiteralPath $projDir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue) {
        $scanned++
        $sessionId = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($existingSessions.ContainsKey($sessionId)) { $skipped++; continue }

        $cwd = Get-CwdFromTranscript $f.FullName
        $project = if ($cwd) { Split-Path -Path $cwd -Leaf } else { $projDir.Name }

        $main = Sum-UsageFromTranscript $f.FullName

        $subSum = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
        $subDir = Join-Path $projDir.FullName (Join-Path $sessionId 'subagents')
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

        if ($total -eq 0) { $skipped++; continue }

        $date = $f.LastWriteTime.ToString('yyyy-MM-dd')
        $newRows += "$date,$project,$sessionId,$inTok,$outTok,$cacheRead,$cacheCreate,$subTotal,$total"
        $added++
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

Write-Host "Scanned: $scanned"
Write-Host "Backfilled (new rows): $added"
Write-Host "Skipped (already logged or empty): $skipped"
Write-Host "Log: $logPath"
