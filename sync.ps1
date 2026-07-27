<#
.SYNOPSIS
    Installs or updates this repo's Claude Code configuration into ~/.claude.

.DESCRIPTION
    Copies claude/scripts/*, claude/CLAUDE.md and claude/settings.json into the
    user's .claude directory. Re-runnable: on an existing install it overwrites
    the scripts and backs up CLAUDE.md / settings.json before replacing them.

    settings.json is stored in the repo with a {{CLAUDE_DIR}} placeholder, which
    is substituted with this machine's actual .claude path on write.

.EXAMPLE
    .\sync.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot   = $PSScriptRoot
$SourceRoot = Join-Path $RepoRoot 'claude'
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$ScriptsDir = Join-Path $ClaudeDir 'scripts'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'

function Test-SameContent {
    param([string]$Left, [string]$Right)

    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) {
        return $false
    }
    (Get-FileHash -LiteralPath $Left).Hash -eq (Get-FileHash -LiteralPath $Right).Hash
}

function Backup-File {
    param([string]$Path)

    $backup = "$Path.bak-$Stamp"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Host "  backed up -> $(Split-Path -Leaf $backup)" -ForegroundColor DarkGray
}

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    throw "Source directory not found: $SourceRoot. Run this script from the repo root."
}

New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null

Write-Host ""
Write-Host "Syncing into $ClaudeDir" -ForegroundColor Cyan
Write-Host ""

# --- scripts -----------------------------------------------------------------
Write-Host "scripts/" -ForegroundColor White

$sourceScripts = Get-ChildItem -LiteralPath (Join-Path $SourceRoot 'scripts') -File
$changed = 0

foreach ($script in $sourceScripts) {
    $target = Join-Path $ScriptsDir $script.Name

    if (Test-SameContent -Left $script.FullName -Right $target) {
        continue
    }

    $verb = if (Test-Path -LiteralPath $target) { 'updated' } else { 'added  ' }
    Copy-Item -LiteralPath $script.FullName -Destination $target -Force
    Write-Host "  $verb $($script.Name)" -ForegroundColor Green
    $changed++
}

if ($changed -eq 0) {
    Write-Host "  up to date ($($sourceScripts.Count) files)" -ForegroundColor DarkGray
}

# --- CLAUDE.md ---------------------------------------------------------------
Write-Host ""
Write-Host "CLAUDE.md" -ForegroundColor White

$claudeMdSource = Join-Path $SourceRoot 'CLAUDE.md'
$claudeMdTarget = Join-Path $ClaudeDir 'CLAUDE.md'

if (Test-SameContent -Left $claudeMdSource -Right $claudeMdTarget) {
    Write-Host "  up to date" -ForegroundColor DarkGray
} else {
    if (Test-Path -LiteralPath $claudeMdTarget) {
        Backup-File -Path $claudeMdTarget
    }
    Copy-Item -LiteralPath $claudeMdSource -Destination $claudeMdTarget -Force
    Write-Host "  written" -ForegroundColor Green
}

# --- settings.json -----------------------------------------------------------
Write-Host ""
Write-Host "settings.json" -ForegroundColor White

$settingsSource = Join-Path $SourceRoot 'settings.json'
$settingsTarget = Join-Path $ClaudeDir 'settings.json'

# Paths sit inside JSON string literals, so backslashes must be doubled.
$escapedDir = $ClaudeDir -replace '\\', '\\'
$rendered   = (Get-Content -LiteralPath $settingsSource -Raw) -replace '\{\{CLAUDE_DIR\}\}', $escapedDir

try {
    $null = $rendered | ConvertFrom-Json
} catch {
    throw "Rendered settings.json is not valid JSON: $($_.Exception.Message)"
}

$existing = if (Test-Path -LiteralPath $settingsTarget) {
    Get-Content -LiteralPath $settingsTarget -Raw
} else {
    $null
}

if ($existing -eq $rendered) {
    Write-Host "  up to date" -ForegroundColor DarkGray
} else {
    if ($null -ne $existing) {
        Backup-File -Path $settingsTarget
    }
    Set-Content -LiteralPath $settingsTarget -Value $rendered -Encoding UTF8 -NoNewline
    Write-Host "  written (hook paths -> $ClaudeDir\scripts)" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Restart Claude Code to pick up settings changes." -ForegroundColor Cyan
Write-Host ""
