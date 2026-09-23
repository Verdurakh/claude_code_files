# Blocks Bash commands that reach into this machine or into Azure, rather than into the repository.
# Companion to block-cd.ps1 on the same PreToolUse Bash matcher. Exit 2 blocks and returns the
# message to Claude, which must then ask rather than route around it.

# Executables Claude may invoke directly. Deliberately empty: ordinary work rarely needs one. Build
# tools are usually reachable without an .exe suffix (Stryker, for example, takes MSBuild.dll), and
# curl.exe tends to appear only inside .ps1 scripts, which the hook never sees. Add a bare file name
# (e.g. 'msbuild.exe') here when a block proves a real need.
$allowedExecutables = @()

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

# 1. Any .exe, wherever it appears. \b after 'exe' keeps C# identifiers such as .ExecuteAsync out.
$executables = [regex]::Matches($cmd, '(?i)[\w.\-]*\.exe\b') |
    ForEach-Object { $_.Value } |
    Select-Object -Unique
$blocked = $executables | Where-Object { $allowedExecutables -notcontains $_.ToLowerInvariant() }

if ($blocked) {
    Deny("this command names $($blocked -join ', '), and running or referencing an executable on this machine is the user's call. Whitelist in scripts/block-machine-reach.ps1 if it is genuinely needed.")
}

# 2. Starting a program, a service or an installer, with or without an .exe suffix.
#
# Two kinds of pattern. The first collide with ordinary English — "start", "net", "sc", "open" — so
# they only count at the head of the command or straight after a separator; otherwise a commit
# message mentioning one is blocked, which trains everyone to route around the hook. The second are
# distinctive enough to match anywhere, which also catches them inside a -Command string.
$commandPosition = '(?:^|[;&|(]\s*)'
$launchers = @(
    "(?i)$commandPosition(start|explorer)\s",
    "(?i)$commandPosition(net|sc)\s+(start|stop|config)\b",
    "(?i)${commandPosition}open\s+-a\b",
    '(?i)\bStart-Process\b',
    '(?i)\bStart-Service\b',
    '(?i)\bStop-Service\b',
    '(?i)\bsystemctl\s',
    '(?i)\bschtasks\b',
    '(?i)\b(winget|choco|scoop)\s+(install|uninstall|upgrade)\b',
    '(?i)\bnpm\s+(i|install)\s+(-g|--global)\b',
    '(?i)\bdocker\s+desktop\b'
)

foreach ($pattern in $launchers) {
    if ($cmd -match $pattern) {
        Deny('this starts, stops or installs something on this machine.')
    }
}

# 3. Azure CLI. Reads are fine; anything that could change the environment is not. Fail closed:
# allowed unless it matches a known read-only shape, so an unrecognised verb blocks rather than runs.
# Command position only: "az" is two letters and turns up inside commit messages and prose.
if ($cmd -match "(?i)${commandPosition}az(\.cmd)?\s") {
    # The verb must appear before the first flag, so a write whose --query or --set value happens to
    # contain the word "list" is not mistaken for a read.
    $azVerbs = ($cmd -split '\s-{1,2}[a-zA-Z]', 2)[0]
    $isRead =
        $cmd -match '(?i)\s(--version|--help|-h)\b' -or
        $azVerbs -match '(?i)\s(list|show|exists|version|get-access-token|list-[a-z-]+|show-[a-z-]+|check-name[a-z-]*)\s*$'

    if (-not $isRead) {
        Deny('az may read the Azure environment but not change it.')
    }
}

exit 0
