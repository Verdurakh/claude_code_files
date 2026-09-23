# Blocks Bash commands that reach into this machine or into Azure, rather than into the repository.
# Companion to block-cd.ps1 on the same PreToolUse Bash matcher. Exit 2 blocks and returns the
# message to Claude, which must then ask rather than route around it.

# Executables Claude may invoke directly. Deliberately empty: ordinary work rarely needs one. Build
# tools are usually reachable without an .exe suffix (Stryker, for example, takes MSBuild.dll), and
# curl.exe tends to appear only inside .ps1 scripts, which the hook never sees. Add a bare file name
# (e.g. 'msbuild.exe') here when a block proves a real need.
$allowedExecutables = @()

# Heads whose arguments are data, not something to run, so naming an .exe there is only a mention.
$readOnlyHeads = @(
    'grep', 'rg', 'git', 'cat', 'ls', 'dir', 'find', 'echo', 'printf', 'head', 'tail', 'sed', 'wc',
    'diff', 'file', 'type', 'findstr', 'select-string', 'get-content', 'get-childitem', 'test'
)

$segmentSeparators = [char[]]@(';', '&', '|', '(', '{', "`n", "`r")

$json = [Console]::In.ReadToEnd()
try {
    $obj = $json | ConvertFrom-Json
    $cmd = $obj.tool_input.command
} catch {
    exit 0
}

if ([string]::IsNullOrWhiteSpace($cmd)) {
    exit 0
}

function Deny([string]$message) {
    [Console]::Error.WriteLine("Blocked: $message Ask the user rather than finding another route.")
    exit 2
}

function Complete-Token([System.Text.StringBuilder]$token, [System.Collections.Generic.List[string]]$tokens) {
    if ($token.Length -gt 0) {
        $tokens.Add($token.ToString())
        [void]$token.Clear()
    }
}

function Complete-Segment(
    [System.Text.StringBuilder]$token,
    [System.Collections.Generic.List[string]]$tokens,
    [System.Collections.Generic.List[string[]]]$segments
) {
    Complete-Token $token $tokens
    if ($tokens.Count -gt 0) {
        $segments.Add($tokens.ToArray())
        $tokens.Clear()
    }
}

# Splits a command line into segments of tokens. A separator inside quotes is part of the text, not
# a separator, so a commit message containing "; start" stays one argument to git. Quote characters
# themselves are dropped, which leaves a quoted -c argument as the plain inner command string.
function Split-Segments([string]$text) {
    $segments = [System.Collections.Generic.List[string[]]]::new()
    $tokens = [System.Collections.Generic.List[string]]::new()
    $token = [System.Text.StringBuilder]::new()
    $quote = $null

    foreach ($c in $text.ToCharArray()) {
        if ($null -ne $quote) {
            if ($c -eq $quote) {
                $quote = $null
            } else {
                [void]$token.Append($c)
            }
        } elseif ($c -eq '"' -or $c -eq "'") {
            $quote = $c
        } elseif ($segmentSeparators -contains $c) {
            Complete-Segment $token $tokens $segments
        } elseif ([char]::IsWhiteSpace($c)) {
            Complete-Token $token $tokens
        } else {
            [void]$token.Append($c)
        }
    }
    Complete-Segment $token $tokens $segments

    return ,$segments
}

# The leaf name, so /usr/bin/systemctl is judged as systemctl.
function Get-Head([string]$token) {
    return ($token -split '[\\/]')[-1].ToLowerInvariant()
}

# The command string a wrapper shell would run: everything after its command flag. Null when the
# flag is absent, e.g. powershell -File script.ps1.
function Get-InnerCommand([string[]]$arguments, [string]$flagPattern) {
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        if ($arguments[$i] -cmatch $flagPattern) {
            return (($arguments | Select-Object -Skip ($i + 1)) -join ' ')
        }
    }
    return $null
}

function Test-Wrapper([string]$head, [string[]]$arguments) {
    if ($head -eq 'powershell' -or $head -eq 'pwsh') {
        if ($arguments | Where-Object { $_ -match '^-(e|ec|enc\w*)$' }) {
            Deny('encoded commands are not allowed, because what they run cannot be checked.')
        }
        return Get-InnerCommand $arguments '(?i)^-c(o|om|omm|omma|omman|ommand)?$'
    }
    if ($head -eq 'cmd') {
        return Get-InnerCommand $arguments '(?i)^/[ck]$'
    }
    # Case-sensitive: bash -C is noclobber, not a command string. Combined flags such as -lc count.
    if ($head -eq 'bash' -or $head -eq 'sh') {
        return Get-InnerCommand $arguments '^-[a-zA-Z]*c[a-zA-Z]*$'
    }
    return $null
}

function Test-Launch([string]$head, [string[]]$arguments) {
    $first = if ($arguments.Count -gt 0) { $arguments[0].ToLowerInvariant() } else { '' }

    $launches =
        $head -in @('start', 'explorer', 'start-process', 'start-service', 'stop-service', 'systemctl', 'schtasks') -or
        ($head -eq 'open' -and $arguments -contains '-a') -or
        ($head -in @('net', 'sc') -and $first -in @('start', 'stop', 'config')) -or
        ($head -in @('winget', 'choco', 'scoop') -and $first -in @('install', 'uninstall', 'upgrade')) -or
        ($head -eq 'npm' -and $first -in @('i', 'install') -and ($arguments -contains '-g' -or $arguments -contains '--global')) -or
        ($head -eq 'docker' -and $first -eq 'desktop')

    if ($launches) {
        Deny('this starts, stops or installs something on this machine.')
    }
}

# Azure CLI. Reads are fine; anything that could change the environment is not. Fail closed:
# allowed unless it matches a known read-only shape, so an unrecognised verb blocks rather than runs.
function Test-Azure([string[]]$tokens) {
    $segment = $tokens -join ' '
    # The verb must appear before the first flag, so a write whose --query or --set value happens to
    # contain the word "list" is not mistaken for a read.
    $azVerbs = ($segment -split '\s-{1,2}[a-zA-Z]', 2)[0]
    $isRead =
        $segment -match '(?i)\s(--version|--help|-h)\b' -or
        $azVerbs -match '(?i)\s(list|show|exists|version|get-access-token|list-[a-z-]+|show-[a-z-]+|check-name[a-z-]*)\s*$'

    if (-not $isRead) {
        Deny('az may read the Azure environment but not change it.')
    }
}

# \b after 'exe' keeps C# identifiers such as .ExecuteAsync out.
function Test-Executables([string[]]$tokens) {
    $executables = $tokens |
        ForEach-Object { [regex]::Matches($_, '(?i)[\w.\-]*\.exe\b') } |
        ForEach-Object { $_.Value } |
        Select-Object -Unique
    $blocked = $executables | Where-Object { $allowedExecutables -notcontains $_.ToLowerInvariant() }

    if ($blocked) {
        Deny("this command names $($blocked -join ', '), and running or referencing an executable on this machine is the user's call. Whitelist in scripts/block-machine-reach.ps1 if it is genuinely needed.")
    }
}

function Test-Segment([string[]]$tokens) {
    $head = Get-Head $tokens[0]
    $arguments = [string[]]@($tokens | Select-Object -Skip 1)

    $inner = Test-Wrapper $head $arguments
    if ($null -ne $inner) {
        Test-Command $inner
        return
    }

    Test-Launch $head $arguments

    if ($head -eq 'az' -or $head -eq 'az.cmd') {
        Test-Azure $tokens
    }

    if ($readOnlyHeads -notcontains $head) {
        Test-Executables $tokens
    }
}

function Test-Command([string]$text) {
    foreach ($segment in (Split-Segments $text)) {
        Test-Segment $segment
    }
}

Test-Command $cmd
exit 0
