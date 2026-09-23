<#
.SYNOPSIS
    Checks Get-ModelRates in token-usage-lib.ps1 against the published per-model prices.

.DESCRIPTION
    Tests the copy in this repo, not the installed one, so a change is verified before it
    is synced onto a machine.

    Prices differ between versions of the same family, so every priced version gets a case.
    The date-suffixed strings matter most: in claude-sonnet-4-20250514 the minor is absent
    and 20250514 is a date, and a parser that reads it as a minor misprices the whole row.

.EXAMPLE
    .\tests\token-usage-lib.tests.ps1
#>

[CmdletBinding()]
param(
    [string]$Lib
)

$ErrorActionPreference = 'Stop'

# Resolved here rather than as a parameter default: $PSScriptRoot is not yet bound while the
# param block is evaluated under Windows PowerShell.
if (-not $Lib) {
    $Lib = Join-Path $PSScriptRoot '..\claude\scripts\token-usage-lib.ps1'
}

. $Lib

$cases = @(
    # Fable and Mythos: 5.1 has the cheaper cache read.
    @{ Model = 'claude-fable-5-1';           Input = 10.00; Output = 50.00; CacheRead = 0.25 },
    @{ Model = 'claude-mythos-5-1';          Input = 10.00; Output = 50.00; CacheRead = 0.25 },
    @{ Model = 'claude-fable-5';             Input = 10.00; Output = 50.00; CacheRead = 1.00 },
    @{ Model = 'claude-mythos-5';            Input = 10.00; Output = 50.00; CacheRead = 1.00 },
    # Opus: three price points.
    @{ Model = 'claude-opus-5-5';            Input =  4.00; Output = 20.00; CacheRead = 0.20 },
    @{ Model = 'claude-opus-5-5[1m]';        Input =  4.00; Output = 20.00; CacheRead = 0.20 },
    @{ Model = 'claude-opus-5';              Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'claude-opus-4-8';            Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'claude-opus-4-7';            Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'claude-opus-4-6';            Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'claude-opus-4-5-20251101';   Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'claude-opus-4-1-20250805';   Input = 15.00; Output = 75.00; CacheRead = 1.50 },
    @{ Model = 'claude-opus-4-20250514';     Input = 15.00; Output = 75.00; CacheRead = 1.50 },
    # Sonnet.
    @{ Model = 'claude-sonnet-5';            Input =  2.00; Output = 10.00; CacheRead = 0.20 },
    @{ Model = 'claude-sonnet-4-6';          Input =  3.00; Output = 15.00; CacheRead = 0.30 },
    @{ Model = 'claude-sonnet-4-5-20250929'; Input =  3.00; Output = 15.00; CacheRead = 0.30 },
    @{ Model = 'claude-sonnet-4-20250514';   Input =  3.00; Output = 15.00; CacheRead = 0.30 },
    @{ Model = 'claude-3-7-sonnet-20250219'; Input =  3.00; Output = 15.00; CacheRead = 0.30 },
    # Haiku.
    @{ Model = 'claude-haiku-4-5-20251001';  Input =  1.00; Output =  5.00; CacheRead = 0.10 },
    # No real model behind the row, so no cost.
    @{ Model = '<synthetic>';                Input =  0;    Output =  0;    CacheRead = 0    },
    # Missing or unknown strings fall back to the Opus 4.5+ rate.
    @{ Model = '';                           Input =  5.00; Output = 25.00; CacheRead = 0.50 },
    @{ Model = 'some-future-model';          Input =  5.00; Output = 25.00; CacheRead = 0.50 }
)

$failed = 0

foreach ($case in $cases) {
    $rates = Get-ModelRates $case.Model
    $label = if ($case.Model) { $case.Model } else { '(empty)' }

    if ($rates.Input -eq $case.Input -and $rates.Output -eq $case.Output -and $rates.CacheRead -eq $case.CacheRead) {
        Write-Host ("  pass  {0}" -f $label) -ForegroundColor DarkGray
    } else {
        $failed++
        Write-Host ("  FAIL  expected {0}/{1}/{2}, got {3}/{4}/{5}: {6}" -f
            $case.Input, $case.Output, $case.CacheRead,
            $rates.Input, $rates.Output, $rates.CacheRead, $label) -ForegroundColor Red
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "$($cases.Count) cases, all passed" -ForegroundColor Green
} else {
    Write-Host "$($cases.Count) cases, $failed failed" -ForegroundColor Red
}

exit $failed
