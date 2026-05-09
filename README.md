# Claude Code Windows Scripts

A collection of scripts, configuration, and sane defaults for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Windows. Includes a notification script, a custom status line, a global `CLAUDE.md`, a baseline `settings.json` with permission rules, and a per-session token usage logger with a cost-estimating report.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [What's included](#whats-included)
  - [notify.ps1](#notifyps1) — Windows toast notification when Claude Code finishes a response
  - [statusline-command.ps1](#statusline-commandps1) — custom status line with model, branch, context %, time
  - [claude-start.bat](#claude-startbat) — pick a Git project from a numbered list and launch `claude` in it
  - [CLAUDE.md](#claudemd) — global coding preferences and conventions
  - [Token usage tracking](#token-usage-tracking) — per-session token log + cost-estimate report (`tokens.cmd`)
  - [Permissions](#permissions) — baseline allow/deny rules for `settings.json`

## Requirements
- Windows 10/11
- PowerShell 5.1+
- Git (for status line branch info)

## Installation

1. Copy the scripts and global config to `~/.claude/`:
```powershell
   mkdir -Force "$env:USERPROFILE\.claude\scripts"
   Copy-Item notify.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item statusline-command.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item log-token-usage.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item backfill-token-usage.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item token-summary.ps1 "$env:USERPROFILE\.claude\scripts\"
   Copy-Item tokens.cmd "$env:USERPROFILE\.claude\scripts\"
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
             },
             {
               "type": "command",
               "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"$HOME/.claude/scripts/log-token-usage.ps1\"",
               "async": true
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

---

## What's included

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

### claude-start.bat
Quickly open any local Git project in Claude Code without manually navigating folders.

What it does:
- Scans the directory where the script is located
- Finds folders containing a `.git` repository (1–2 levels deep)
- Displays them as a numbered list
- Lets you pick a project
- Starts `claude` in the selected folder

Usage:
- Place the script in a directory containing your projects
- Run it (double-click or from terminal)
- Select a project by number

Notes:
- Uses `%~dp0`, so it always runs relative to its own location
- Requires `claude` to be available in PATH
- Only detects Git repositories (`.git` folder required)
- Scans up to 2 levels deep (intentional to keep it fast)

### CLAUDE.md
A global `CLAUDE.md` that defines general coding preferences and behavior for Claude Code across all your projects — things like communication style, coding defaults, git conventions, and shell behavior. Intentionally generic and not tied to any specific project or tech stack.

For project-specific instructions, create a `CLAUDE.md` in the root of each project — Claude Code will pick it up automatically and layer it on top of the global one.

### Token usage tracking

Four scripts that work together to record per-session token usage and let you see where your tokens (and money equivalent, at API rates) go over time. Useful both for understanding your own patterns and for pricing out "what would this have cost on the API?" if you're on a Pro/Max subscription.

**The pieces:**

- **`log-token-usage.ps1`** — runs as a `Stop` hook (configured in the `settings.json` above). On every Stop event Claude Code passes it the session's `transcript_path` on stdin. The script reads the transcript JSONL, sums `input` / `output` / `cache_read` / `cache_creation` token counts across all assistant messages, also sums any subagent transcripts under `<session>/subagents/agent-*.jsonl`, and upserts a row keyed by `session_id` into `~/.claude/token-usage.csv`. Concurrency-safe via a named global mutex so two sessions stopping at once don't corrupt the file. Runs `async: true` so it never blocks the UI.
- **`backfill-token-usage.ps1`** — one-shot history seeder. Walks every parent transcript under `~/.claude/projects/**/*.jsonl`, applies the same summing logic, and adds rows for any session not already in the CSV. Re-runnable; never duplicates. Note that Claude Code only retains transcripts for `cleanupPeriodDays` (default 30), so you'll only get the last ~month of history.
- **`token-summary.ps1`** — pretty-printed report over a sliding window. Shows raw token activity, an estimated API-cost breakdown using published Anthropic rates, a per-project table, and a per-day timeline. Cache writes are shown as a 5m–1h TTL cost range (since the CSV doesn't break those out separately).
- **`tokens.cmd`** — a Windows wrapper so you can run `tokens.cmd -Days 30` from any shell instead of typing the full PowerShell invocation. Add `~/.claude/scripts` to your PATH if you want to type just `tokens` from anywhere.

**What gets stored:**

A single CSV at `~/.claude/token-usage.csv` with these columns:

```
date, project, session_id, input, output, cache_read, cache_creation, subagent_total, total
```

`project` is the leaf directory of the session's `cwd` (e.g. `my-app` from `C:\Users\you\code\my-app`). `subagent_total` is how much of `total` came from subagent transcripts.

**Usage:**

```powershell
tokens.cmd                          # last 7 days, all projects, Opus pricing
tokens.cmd -Days 30                 # last 30 days
tokens.cmd -Days 30 -Project my-app # filter to one project
tokens.cmd -Days 7 -TopSessions 5   # also list the 5 highest-token sessions
tokens.cmd -Days 30 -Pricing sonnet # estimate with Sonnet rates instead
```

After installing, run the backfill once to seed historical data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\backfill-token-usage.ps1"
```

**Example output** (`tokens.cmd -Days 7`):

```
Token usage - last 7 day(s)  (2026-05-03 to 2026-05-09)
========================================================================

RAW TOKEN ACTIVITY
------------------------------------------------------------------------
  Total                 265,462,664   (11 sessions)
    input                    18,824
    output                1,560,856
    cache read          253,607,256   <- re-reads of cached prompt prefix
    cache write          10,275,728   <- new cache entries
  Subagents              22,688,913   (8.5% of total)
  Cache hit                  96.1%   (read / (read+write); higher = better reuse)

ESTIMATED API COST  (preset: Claude Opus 4 standard (<=200K input))
------------------------------------------------------------------------
  input         @  $ 15.00/M       $        0.28
  output        @  $ 75.00/M       $      117.06
  cache write   @  $ 18.75/M (5m)  $      192.67   to  $      308.27 ($ 30.00/M @ 1h TTL)
  cache read    @  $  1.50/M       $      380.41
  ----------------------------------------------------------------------
  Estimated cost                    $      690.42   to  $      806.02

  (If you're on a Pro/Max subscription, this is informational only - not your bill.)
  (Range reflects unknown 5m vs 1h cache-write TTL. 1M-context tier > 200K input is priced higher.)

BY PROJECT
------------------------------------------------------------------------
  Project                                      Tokens Est. $ (5m)  Sess  Sub%
  my-app                                  212,185,909     $551.36     6  3.5%
  web-tool                                 49,500,055     $128.45     3 30.7%
  side-project                              3,776,700       $9.81     2    0%

BY DAY
------------------------------------------------------------------------
  2026-05-09        47,767,846      $124.18   (2 sessions)
  2026-05-08         1,732,209        $4.51   (1 sessions)
  2026-05-07                 -            -   (0 sessions)
  2026-05-06         3,776,700        $9.81   (2 sessions)
  2026-05-05         4,139,121       $12.64   (1 sessions)
  2026-05-04        26,513,640       $73.91   (2 sessions)
  2026-05-03       181,533,148      $465.38   (3 sessions)
```

**Things worth knowing:**

- The Stop hook fires every time Claude stops responding within a session, not just at session end. The script handles that by upserting on `session_id` — each Stop overwrites that session's row with the latest cumulative totals. No double-counting.
- The cost estimate uses Anthropic's published Opus 4 / Sonnet 4 standard rates. The 1M-context Opus tier costs more for input above 200K, so heavy-context users will see the real API equivalent be somewhat higher than what's reported.
- The cache hit ratio is the metric to actually watch over time. A high ratio (>90%) means your prompt structure is stable and prompt caching is doing its job. A drop below ~80% suggests something is invalidating the cache often, which gets expensive fast.
- The CSV is yours alone — don't commit it to a repo. It contains your project names and full session-by-session usage history.

### Permissions
The `settings.json` above includes a baseline permissions configuration. Deny rules always take precedence over allow rules regardless of order, so the strategy is to allow broadly and deny the dangerous stuff explicitly. Adjust to fit your workflow.

#### Allow

| Rule | Reason |
|------|--------|
| `Read(**)` | Allows Claude to read any file in the working directory without prompting. Claude needs this constantly for context — restricting it just creates noise. |

#### Deny

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
