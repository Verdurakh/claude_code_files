$json = [Console]::In.ReadToEnd()
try {
    $obj = $json | ConvertFrom-Json
    $cmd = $obj.tool_input.command
} catch {
    exit 0
}

if ($cmd -match '^\s*cd\s+[^&;|]+\s*(&&|;)') {
    [Console]::Error.WriteLine('Blocked: do not prefix commands with cd, you are already in the working directory. Run the command directly.')
    exit 2
}
exit 0