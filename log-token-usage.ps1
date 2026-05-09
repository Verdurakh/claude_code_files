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

try {
    $stdin = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdin)) { exit 0 }
    $payload = $stdin | ConvertFrom-Json

    $transcriptPath = $payload.transcript_path
    $sessionId      = $payload.session_id
    $cwd            = $payload.cwd
    if (-not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) { exit 0 }
    if (-not $sessionId) { exit 0 }

    $project = if ($cwd) { Split-Path -Path $cwd -Leaf } else { '<unknown>' }

    $main = Sum-UsageFromTranscript $transcriptPath

    $subSum = [pscustomobject]@{ Input = 0L; Output = 0L; CacheRead = 0L; CacheCreate = 0L }
    $projectDir   = Split-Path -Path $transcriptPath -Parent
    $subagentsDir = Join-Path $projectDir (Join-Path $sessionId 'subagents')
    if (Test-Path -LiteralPath $subagentsDir) {
        Get-ChildItem -LiteralPath $subagentsDir -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
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

    $logPath = Join-Path $HOME '.claude\token-usage.csv'
    $date    = (Get-Date).ToString('yyyy-MM-dd')
    $header  = 'date,project,session_id,input,output,cache_read,cache_creation,subagent_total,total'
    $newRow  = "$date,$project,$sessionId,$inTok,$outTok,$cacheRead,$cacheCreate,$subTotal,$total"

    $mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeTokenUsageLog')
    [void]$mutex.WaitOne()
    try {
        $rows = @($header)
        if (Test-Path -LiteralPath $logPath) {
            $existing = Get-Content -LiteralPath $logPath
            if ($existing.Count -gt 0) {
                $startIdx = if ($existing[0] -eq $header -or $existing[0] -like 'date,project,session_id,*') { 1 } else { 0 }
                for ($i = $startIdx; $i -lt $existing.Count; $i++) {
                    $r = $existing[$i]
                    if ([string]::IsNullOrWhiteSpace($r)) { continue }
                    $cols = $r.Split(',')
                    if ($cols.Length -ge 3 -and $cols[2] -eq $sessionId) { continue }
                    $rows += $r
                }
            }
        }
        $rows += $newRow
        [System.IO.File]::WriteAllLines($logPath, $rows, [System.Text.UTF8Encoding]::new($false))
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
    exit 0
} catch {
    exit 0
}
