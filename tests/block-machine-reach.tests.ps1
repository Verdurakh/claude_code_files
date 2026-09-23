<#
.SYNOPSIS
    Checks block-machine-reach.ps1 against the commands it must block and must not.

.DESCRIPTION
    Tests the copy in this repo, not the installed one, so a change is verified before it
    is synced onto a machine.

    The must-pass half matters as much as the must-block half. The guard matches on text, so
    an over-eager pattern rejects commit messages and greps that merely mention "start" or
    "az" — and a guard that fires on innocent commands is one people learn to work around.

.EXAMPLE
    .\tests\block-machine-reach.tests.ps1
#>

[CmdletBinding()]
param(
    [string]$Hook
)

$ErrorActionPreference = 'Stop'

# Resolved here rather than as a parameter default: $PSScriptRoot is not yet bound while the
# param block is evaluated under Windows PowerShell.
if (-not $Hook) {
    $Hook = Join-Path $PSScriptRoot '..\claude\scripts\block-machine-reach.ps1'
}

$cases = @(
    # Prose that merely names a blocked word — these must run.
    @{ Expect = 0; Cmd = 'git commit -m "add a guard hook that blocks installs and az writes"' },
    @{ Expect = 0; Cmd = 'git commit -m "start the retry loop when the queue is empty"' },
    @{ Expect = 0; Cmd = 'git log --oneline --grep "net start"' },
    @{ Expect = 0; Cmd = 'grep -rn az Docs' },
    # Ordinary work.
    @{ Expect = 0; Cmd = 'dotnet build -warnaserror' },
    @{ Expect = 0; Cmd = 'dotnet test tests/Some.ContractTests' },
    @{ Expect = 0; Cmd = 'dotnet dotnet-stryker --msbuild-path "/c/sdk/MSBuild.dll"' },
    @{ Expect = 0; Cmd = 'grep -rn ExecuteAsync src' },
    # Azure reads.
    @{ Expect = 0; Cmd = 'az group list --output table' },
    @{ Expect = 0; Cmd = 'az containerapp show --name x --resource-group rg' },
    @{ Expect = 0; Cmd = 'az account get-access-token' },
    @{ Expect = 0; Cmd = 'az --version' },
    # Azure writes, including one whose flag value contains a read verb.
    @{ Expect = 2; Cmd = 'az group create --name x' },
    @{ Expect = 2; Cmd = 'az appconfig kv set --key Foo --value true' },
    @{ Expect = 2; Cmd = 'az containerapp update --name x --query list' },
    @{ Expect = 2; Cmd = 'echo hi && az containerapp update --name x' },
    # Launching and installing.
    @{ Expect = 2; Cmd = 'start notepad' },
    @{ Expect = 2; Cmd = 'net start MyService' },
    @{ Expect = 2; Cmd = 'powershell -Command "Start-Process notepad"' },
    @{ Expect = 2; Cmd = 'winget install Foo' },
    @{ Expect = 2; Cmd = 'npm install -g some-cli' },
    # The incident this guard exists for.
    @{ Expect = 2; Cmd = '"/c/Program Files/Docker/Docker/Docker Desktop.exe" & sleep 2' }
)

$failed = 0

# The hook writes its refusal to stderr, which Windows PowerShell turns into a terminating
# NativeCommandError while ErrorActionPreference is Stop. Exit codes are what this checks.
$ErrorActionPreference = 'Continue'

foreach ($case in $cases) {
    $payload = @{ tool_name = 'Bash'; tool_input = @{ command = $case.Cmd } } | ConvertTo-Json -Compress
    $payload | & powershell -NoProfile -ExecutionPolicy Bypass -File $Hook > $null 2>&1
    $actual = $LASTEXITCODE

    if ($actual -eq $case.Expect) {
        Write-Host ("  pass  {0}" -f $case.Cmd) -ForegroundColor DarkGray
    } else {
        $failed++
        Write-Host ("  FAIL  expected {0}, got {1}: {2}" -f $case.Expect, $actual, $case.Cmd) -ForegroundColor Red
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "$($cases.Count) cases, all passed" -ForegroundColor Green
} else {
    Write-Host "$($cases.Count) cases, $failed failed" -ForegroundColor Red
}

exit $failed
