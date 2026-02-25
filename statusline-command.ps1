# Read JSON input from stdin
$input_data = $input | ConvertFrom-Json

# ANSI color codes
$esc = [char]27
$reset = "$esc[0m"
$dim = "$esc[38;2;136;136;136m"
$purple = "$esc[38;2;168;85;247m"
$cyan = "$esc[38;2;34;211;238m"
$magenta = "$esc[38;2;236;72;153m"
$green = "$esc[38;2;34;197;94m"
$yellow = "$esc[38;2;250;204;21m"
$orange = "$esc[38;2;249;115;22m"
$red = "$esc[38;2;239;68;68m"

# Extract useful information
$cwd = $input_data.workspace.current_dir
$model_name = $input_data.model.display_name
$vim_mode = if ($input_data.vim) { $input_data.vim.mode } else { $null }

# Get directory name
$dir_name = Split-Path -Leaf $cwd

# Get git branch and status if in a git repo
$git_info = ""
if (Test-Path (Join-Path $cwd ".git")) {
    try {
        Push-Location $cwd
        $branch = git rev-parse --abbrev-ref HEAD 2>$null
        if ($branch) {
            # Check if working directory is clean
            $status = git status --porcelain 2>$null
            if ($status) {
                $dirty_indicator = "$yellow*$reset"
            } else {
                $dirty_indicator = "$green$([char]0x2713)$reset"
            }
            # Remove folder prefixes like feature/, fix/, refactor/
            $short_branch = $branch -replace '^.+/', ''
            $git_info = "$magenta$short_branch$reset$dirty_indicator"
        }
        Pop-Location
    } catch {
        Pop-Location
    }
}

# Calculate context window with token counts and color
$context_info = ""
if ($input_data.context_window.current_usage) {
    $usage = $input_data.context_window.current_usage
    $current = $usage.input_tokens + $usage.cache_creation_input_tokens + $usage.cache_read_input_tokens
    $size = $input_data.context_window.context_window_size
    if ($size -gt 0) {
        $pct = [math]::Floor(($current * 100) / $size)
        # Format token counts (e.g., 12K/200K)
        $current_k = [math]::Round($current / 1000)
        $size_k = [math]::Round($size / 1000)

        # Color based on percentage (green -> yellow -> orange -> red as approaching 80%)
        if ($pct -lt 40) {
            $pct_color = $green
        } elseif ($pct -lt 60) {
            $pct_color = $yellow
        } elseif ($pct -lt 75) {
            $pct_color = $orange
        } else {
            $pct_color = $red
        }

        $context_info = "$dim${current_k}K/${size_k}K$reset ($pct_color$pct%$reset)"
    }
}

# Get current time
$time = Get-Date -Format "HH:mm"

# Build status line parts
$parts = @()
if ($model_name) { $parts += "$purple$model_name$reset" }
$parts += "$cyan$dir_name$reset"
if ($git_info) { $parts += $git_info }
if ($context_info) { $parts += $context_info }
$parts += "$dim$time$reset"

# Add vim mode indicator if enabled
if ($vim_mode) {
    $mode_color = if ($vim_mode -eq "INSERT") { $green } else { $cyan }
    $mode_indicator = if ($vim_mode -eq "INSERT") { "INS" } else { "NOR" }
    $parts += "$mode_color$mode_indicator$reset"
}

$separator = " $dim|$reset "
$status = $parts -join $separator
Write-Host $status
