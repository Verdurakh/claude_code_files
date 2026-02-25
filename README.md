  # Claude Code Windows Scripts

  PowerShell scripts for enhancing [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Windows.

  ## Scripts

  ### notify.ps1

  Sends a Windows toast notification when Claude Code finishes a response. Only triggers when the terminal is **not** in the foreground, so it won't interrupt you if you're already watching.

  ### statusline-command.ps1

  A custom status line that displays:

  - **Model name** (purple)
  - **Current directory** (cyan)
  - **Git branch** with dirty/clean indicator (magenta + yellow/green)
  - **Context window usage** with color-coded percentage (green → yellow → orange → red)
  - **Current time**
  - **Vim mode** indicator (if enabled)

  ## Installation

  1. Copy both scripts to `~/.claude/scripts/`:

     ```powershell
     mkdir -Force "$env:USERPROFILE\.claude\scripts"
     Copy-Item notify.ps1 "$env:USERPROFILE\.claude\scripts\"
     Copy-Item statusline-command.ps1 "$env:USERPROFILE\.claude\scripts\"
     ```

  2. Add the following to `~/.claude/settings.json`:

     ```json
     {
       "statusLine": {
         "type": "command",
         "command": "powershell -ExecutionPolicy Bypass -File \"$HOME/.claude/scripts/statusline-command.ps1\""
       },
       "hooks": {
         "Stop": [
           {
             "matcher": "",
             "hooks": [
               {
                 "type": "command",
                 "command": "powershell -ExecutionPolicy Bypass -File \"$HOME/.claude/scripts/notify.ps1\" \"Claude Code has finished\""
               }
             ]
           }
         ]
       }
     }
     ```

  ## Requirements

  - Windows 10/11
  - PowerShell 5.1+
  - Git (for status line branch info)
