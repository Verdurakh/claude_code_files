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

## Global CLAUDE.md

A global `CLAUDE.md` is included in this repo. It defines general coding preferences and behavior for Claude Code that apply across all projects — things like communication style, coding defaults, git conventions, and shell behavior.

Copy it to your Claude config directory:
```powershell
Copy-Item CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
```

This file is intentionally generic and not tied to any specific project or tech stack. For project-specific instructions, create a `CLAUDE.md` in the root of each project — Claude Code will pick that up automatically and layer it on top of the global one.

## Installation

1. Copy the scripts and global config to `~/.claude/`:
```powershell
   mkdir -Force "$env:USERPROFILE\.claude\scripts"
   Copy-Item notify.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item statusline-command.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item CLAUDE.md "$env:USERPROFILE\.claude\CLAUDE.md"
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
     },
     "permissions": {
       "allow": [
         "Read(**)"
       ],
       "deny": [
         "Bash(rm -rf*)",
         "Bash(rm -fr*)",
         "Bash(sudo *)",
         "Bash(dd *)",
         "Bash(mkfs *)",
         "Bash(format *)",
         "Bash(wget *|bash*)",
         "Bash(wget *| bash*)",
         "Bash(git push --force*)",
         "Bash(git push *--force*)",
         "Bash(git reset --hard*)",
         "Bash(shutdown *)",
         "Bash(reboot *)",
         "Bash(taskkill *)",
         "Bash(reg *)",
         "Bash(regedit *)",
         "Bash(bcdedit *)",
         "Bash(diskpart *)",
         "Bash(netsh *)",
         "Edit(~/.bashrc)",
         "Edit(~/.zshrc)",
         "Edit(~/.profile)",
         "Edit(~/.ssh/**)",
         "Read(~/.ssh/**)",
         "Read(~/.gnupg/**)",
         "Read(~/.git-credentials)",
         "Read(~/.docker/config.json)",
         "Read(~/.npmrc)",
         "Read(~/.pypirc)",
         "Read(~/.gem/credentials)",
         "Read(**/.env)",
         "Read(**/.env.local)",
         "Read(**/.env.development)",
         "Read(**/.env.staging)",
         "Read(**/.env.production)",
         "Read(**/.env.test)",
         "Edit(**/.env)",
         "Edit(**/.env.local)",
         "Edit(**/.env.development)",
         "Edit(**/.env.staging)",
         "Edit(**/.env.production)",
         "Edit(**/.env.test)"
       ]
     }
   }
```

## Permissions

The `settings.json` above includes a baseline permissions configuration. Deny rules always take precedence over allow rules regardless of order, so the strategy is to allow broadly and deny the dangerous stuff explicitly. Adjust to fit your workflow.

### Allow

| Rule | Reason |
|------|--------|
| `Read(**)` | Allows Claude to read any file in the working directory without prompting. Claude needs this constantly for context — restricting it just creates noise. |

### Deny

| Rule | Reason |
|------|--------|
| `Bash(rm -rf*)` `Bash(rm -fr*)` | Recursive force deletion. One of the most dangerous commands you can run — blocks both flag orderings. Plain `rm` on a single file is still allowed. |
| `Bash(sudo *)` | Blocks all privilege escalation. Claude should never need to run as root. |
| `Bash(dd *)` | Low-level disk writing that can overwrite drives or partitions with no confirmation. |
| `Bash(mkfs *)` | Formats a filesystem — effectively wiping a disk or partition. |
| `Bash(format *)` | Windows equivalent of `mkfs`. |
| `Bash(wget *\|bash*)` `Bash(wget *\| bash*)` | Blocks the pipe-to-bash pattern (`wget url \| bash`) used in supply chain attacks. Both spacings covered. |
| `Bash(git push --force*)` `Bash(git push *--force*)` | Force push rewrites remote history and can permanently destroy work for the whole team. Both flag positions covered. |
| `Bash(git reset --hard*)` | Discards all uncommitted changes with no recovery path. |
| `Bash(shutdown *)` `Bash(reboot *)` | Prevents Claude from shutting down or rebooting the machine mid-session. |
| `Bash(taskkill *)` | Blocks killing arbitrary system processes on Windows. |
| `Bash(reg *)` `Bash(regedit *)` | Prevents modifications to the Windows registry. |
| `Bash(bcdedit *)` | Blocks changes to the Windows boot configuration. |
| `Bash(diskpart *)` | Blocks the Windows disk partitioning tool. |
| `Bash(netsh *)` | Prevents changes to Windows network configuration. |
| `Edit(~/.bashrc)` `Edit(~/.zshrc)` `Edit(~/.profile)` | Shell config files — modifying these affects every future terminal session. |
| `Edit(~/.ssh/**)` `Read(~/.ssh/**)` | SSH keys and config. No reason for Claude to read or touch these. |
| `Read(~/.gnupg/**)` | GPG keys used for signing commits and encrypting data. |
| `Read(~/.git-credentials)` | Stores plaintext Git credentials. |
| `Read(~/.docker/config.json)` | Contains Docker registry auth tokens. |
| `Read(~/.npmrc)` `Read(~/.pypirc)` `Read(~/.gem/credentials)` | Package registry credentials for npm, PyPI, and RubyGems. |
| `Read(**/.env)` `Read(**/.env.*)` | Env files anywhere in the project tree. These typically contain secrets, API keys, and database URLs. `.env.example` and `.env.sample` are intentionally not blocked since they contain no real secrets. |
| `Edit(**/.env)` `Edit(**/.env.*)` | Same as above — prevents Claude from modifying env files even if it can't read them. |

## Requirements
- Windows 10/11
- PowerShell 5.1+
- Git (for status line branch info)
