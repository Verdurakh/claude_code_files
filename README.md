# Claude Code Windows Scripts

A collection of scripts, configuration, and sane defaults for running [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Windows. Includes a notification script, a custom status line, a `cd`-blocking guard hook, a global `CLAUDE.md`, a `settings.json` with permission rules, and per-session token usage tracking with both a terminal report and an HTML dashboard.

Everything under `claude/` mirrors the real `~/.claude` tree, and `sync.ps1` copies it into place. Cloning this repo onto a new machine and running one command gets you the same setup.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Updating](#updating)
- [Repo layout](#repo-layout)
- [What's included](#whats-included)
  - [notify.ps1](#notifyps1) — Windows toast notification when Claude Code finishes a response
  - [statusline-command.ps1](#statusline-commandps1) — custom status line with model, branch, context %, time
  - [block-cd.ps1](#block-cdps1) — guard hook that rejects `cd ... &&` command prefixes
  - [claude-start.bat](#claude-startbat) — pick a Git project from a numbered list and launch `claude` in it
  - [CLAUDE.md](#claudemd) — global coding preferences and conventions
  - [Token usage tracking](#token-usage-tracking) — per-session token log, terminal report, HTML dashboard
  - [settings.json](#settingsjson) — hooks, status line, model/effort defaults, permissions
  - [Permissions](#permissions) — baseline allow/deny rules

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Git (for status line branch info)

## Installation

```powershell
git clone https://github.com/<you>/claude_code_files.git
cd claude_code_files
.\sync.cmd
```

Then restart Claude Code so it picks up the new `settings.json`.

`sync.cmd` is a thin wrapper that invokes `sync.ps1` with `-ExecutionPolicy Bypass`, so it works on a machine with the default Restricted policy and can also be double-clicked. To call the script directly instead:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync.ps1
```

`sync.ps1` copies `claude/scripts/*` into `~/.claude/scripts`, `claude/CLAUDE.md` into `~/.claude/CLAUDE.md`, and writes `~/.claude/settings.json`. The repo's `settings.json` stores hook and status line paths as a `{{CLAUDE_DIR}}` placeholder, which `sync.ps1` substitutes with the actual path on that machine — so the same committed file works under any user profile.

Optionally seed historical token data (see [Token usage tracking](#token-usage-tracking)):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\backfill-token-usage.ps1"
```

## Updating

On any machine that already has this repo cloned:

```powershell
git pull
.\sync.cmd
```

`sync.ps1` is re-runnable and safe to call repeatedly:

- **Scripts** are overwritten from the repo; unchanged files are skipped and it reports what it touched.
- **`CLAUDE.md`** and **`settings.json`** are backed up to `<name>.bak-<timestamp>` before being replaced, but only when they actually differ. Local edits aren't lost — but the repo is the source of truth, so make changes here and sync outward rather than editing `~/.claude` directly.
- A run with nothing to do prints `up to date` and writes no backups.

## Repo layout

```
claude/
  CLAUDE.md              -> ~/.claude/CLAUDE.md
  settings.json          -> ~/.claude/settings.json  (paths substituted)
  scripts/               -> ~/.claude/scripts/
    notify.ps1
    statusline-command.ps1
    block-cd.ps1
    log-token-usage.ps1
    backfill-token-usage.ps1
    token-usage-lib.ps1
    token-summary.ps1
    token-dashboard.ps1
    tokens.cmd
    token-dashboard.cmd
    token-dashboard-14.cmd
    token-dashboard-30.cmd
    token-dashboard-all.cmd
claude-start.bat         (not part of ~/.claude — see below)
sync.ps1
sync.cmd                 (wrapper: runs sync.ps1 with -ExecutionPolicy Bypass)
```

---

## What's included

### notify.ps1

Sends a Windows toast notification when Claude Code finishes a response. Only triggers when the terminal is **not** in the foreground, so it won't interrupt you if you're already watching. Wired up as a `Stop` hook.

### statusline-command.ps1

A custom status line that displays:

- **Model name** (purple)
- **Current directory** (cyan)
- **Git branch** with dirty/clean indicator (magenta + yellow/green)
- **Context window usage** with color-coded percentage (green → yellow → orange → red)
- **Current time**
- **Vim mode** indicator (if enabled)

### block-cd.ps1

A `PreToolUse` hook on the `Bash` tool. Reads the proposed command from stdin and exits with code 2 — rejecting the call with an explanation — if it starts with a `cd <path> &&` or `cd <path>;` prefix.

Claude has a habit of prefixing every shell command with a `cd` into the working directory it's already in. That's noise, and worse, it defeats permission-rule matching: an allow rule for `Bash(git status:*)` doesn't match `cd /some/path && git status`, so you get prompted for commands you already approved. The `CLAUDE.md` rule alone gets ignored often enough that a hard block is worth it.

### claude-start.bat

Quickly open any local Git project in Claude Code without manually navigating folders. This one does **not** live in `~/.claude` and isn't touched by `sync.ps1` — put it in whatever directory holds your projects.

What it does:

- Scans the directory where the script is located
- Finds folders containing a `.git` repository (1–2 levels deep)
- Displays them as a numbered list
- Lets you pick a project
- Starts `claude` in the selected folder

Notes:

- Uses `%~dp0`, so it always runs relative to its own location
- Requires `claude` to be available in PATH
- Only detects Git repositories (`.git` folder required)
- Scans up to 2 levels deep (intentional, to keep it fast)

### CLAUDE.md

A global `CLAUDE.md` that defines general coding preferences and behavior for Claude Code across all your projects — communication style, coding defaults, working approach, git conventions, and shell behavior. Intentionally generic and not tied to any specific project or tech stack.

For project-specific instructions, create a `CLAUDE.md` in the root of each project — Claude Code will pick it up automatically and layer it on top of the global one.

### Token usage tracking

A set of scripts that record per-session token usage and let you see where your tokens (and money equivalent, at API rates) go over time. Useful both for understanding your own patterns and for pricing out "what would this have cost on the API?" if you're on a Pro/Max subscription.

**The pieces:**

- **`log-token-usage.ps1`** — runs as a `Stop` hook. On every Stop event Claude Code passes it the session's `transcript_path` on stdin. The script reads the transcript JSONL, sums `input` / `output` / `cache_read` / `cache_creation` token counts across all assistant messages, also sums any subagent transcripts under `<session>/subagents/agent-*.jsonl`, and upserts a row keyed by `session_id` into `~/.claude/token-usage.csv`. It also writes a per-model sidecar to `~/.claude/token-usage-by-model.csv`, one row per (session, scope, model), so costs can be attributed to the model that actually ran. Concurrency-safe via named global mutexes so two sessions stopping at once don't corrupt either file. Runs `async: true` so it never blocks the UI.
- **`backfill-token-usage.ps1`** — one-shot history seeder. Walks every parent transcript under `~/.claude/projects/**/*.jsonl`, applies the same summing logic, and adds rows for any session not already in the CSV. Re-runnable; never duplicates. Note that Claude Code only retains transcripts for `cleanupPeriodDays` (default 30), so you'll only get the last ~month of history.
- **`token-usage-lib.ps1`** — shared library dot-sourced by the reporting scripts. Holds the pricing presets, per-model rate lookup, CSV loaders, and the cost math. Not run directly.
- **`token-summary.ps1`** — pretty-printed terminal report over a sliding window. Raw token activity, estimated API cost, per-model / per-project / per-day breakdowns. Cache writes are shown as a 5m–1h TTL cost range (since the CSV doesn't break those out separately).
- **`token-dashboard.ps1`** — generates a standalone HTML dashboard at `~/.claude/token-dashboard.html` and opens it. Same data as the summary, but charted. Takes the same parameters, plus `-Days 0` for all-time.
- **`.cmd` wrappers** — `tokens.cmd` (summary), `token-dashboard.cmd`, and the `-14` / `-30` / `-all` dashboard presets. Add `~/.claude/scripts` to your PATH if you want to type just `tokens` from anywhere.

**What gets stored:**

`~/.claude/token-usage.csv`:

```
date, project, session_id, input, output, cache_read, cache_creation, subagent_total, total
```

`~/.claude/token-usage-by-model.csv`:

```
date, project, session_id, scope, model, input, output, cache_read, cache_creation, total
```

`project` is the leaf directory of the session's `cwd` (e.g. `my-app` from `C:\Users\you\code\my-app`). `subagent_total` is how much of `total` came from subagent transcripts. `scope` distinguishes main-session rows from subagent rows.

**Usage:**

```powershell
tokens.cmd                          # last 7 days, all projects
tokens.cmd -Days 30                 # last 30 days
tokens.cmd -Days 30 -Project my-app # filter to one project
tokens.cmd -Days 7 -TopSessions 5   # also list the 5 highest-token sessions
tokens.cmd -Days 30 -Pricing sonnet # fallback rate for sessions with no model data

token-dashboard.cmd                 # HTML dashboard, last 7 days
token-dashboard-30.cmd              # last 30 days
token-dashboard-all.cmd             # all time
```

**Example output** (`tokens.cmd -Days 7`):

```
Token usage - last 7 day(s)  (2026-07-21 to 2026-07-27)
========================================================================

RAW TOKEN ACTIVITY
------------------------------------------------------------------------
  Total                 189,855,896   (7 sessions)
    input                    23,784
    output                1,769,018
    cache read          183,880,834   <- re-reads of cached prompt prefix
    cache write           4,182,260   <- new cache entries
  Subagents                       0   (0% of total)
  Cache hit                   97.8%   (read / (read+write); higher = better reuse)

ESTIMATED API COST  (per-model where available; Claude Opus 4.5+ standard (<=200K input) for the rest)
------------------------------------------------------------------------
  input                          $        0.12
  output                         $       44.23
  cache write (5m TTL)           $       26.14   to  $       41.82 (1h TTL)
  cache read                     $       91.94
  ----------------------------------------------------------------------
  Estimated cost                 $      162.42   to  $      178.11

  Sessions priced per-model: 7 / 7   (remaining 0 assumed opus)
  (If you're on a Pro/Max subscription, this is informational only - not your bill.)
  (Range reflects unknown 5m vs 1h cache-write TTL. 1M-context tier > 200K input is priced higher.)

BY MODEL
------------------------------------------------------------------------
  Model                                       Tokens Est. $ (5m)  Sub%
  claude-opus-4-8                        161,864,744     $136.25    0%
  claude-opus-5                           27,991,152      $26.18    0%

BY PROJECT
------------------------------------------------------------------------
  Project                                           Tokens Est. $ (5m)  Sess  Sub%
  my-app                                       165,265,197     $140.96     4    0%
  web-tool                                      21,777,749      $16.51     1    0%
  side-project                                   2,033,945       $3.15     1    0%
  claude_code_files                                779,005       $1.80     1    0%

BY DAY
------------------------------------------------------------------------
  2026-07-27           779,005        $1.80   (1 sessions)
  2026-07-26                 -            -   (0 sessions)
  2026-07-25         5,434,398        $7.86   (1 sessions)
  2026-07-24       146,416,601      $111.72   (2 sessions)
  2026-07-23        35,191,947       $37.89   (2 sessions)
  2026-07-22                 -            -   (0 sessions)
  2026-07-21         2,033,945        $3.15   (1 sessions)
```

**Things worth knowing:**

- The Stop hook fires every time Claude stops responding within a session, not just at session end. The script handles that by upserting on `session_id` — each Stop overwrites that session's row with the latest cumulative totals. No double-counting.
- Sessions logged since the per-model sidecar existed are priced with each model's own rates. Older rows have no model data and fall back to the `-Pricing` preset (default Opus); the report tells you how many rows fell back.
- The 1M-context Opus tier costs more for input above 200K, which isn't modelled — heavy-context users will see the real API equivalent be somewhat higher than what's reported.
- The cache hit ratio is the metric to actually watch over time. A high ratio (>90%) means your prompt structure is stable and prompt caching is doing its job. A drop below ~80% suggests something is invalidating the cache often, which gets expensive fast.
- The CSVs are yours alone — don't commit them to a repo. They contain your project names and full session-by-session usage history.

### settings.json

The committed `claude/settings.json` covers:

| Setting | What it does |
|---------|--------------|
| `hooks.Stop` | Runs `notify.ps1` and `log-token-usage.ps1`, both `async` so neither blocks the UI. |
| `hooks.PreToolUse` | Runs `block-cd.ps1` on the `Bash` tool. |
| `statusLine` | Runs `statusline-command.ps1`. |
| `model` | Default model (`opus[1m]` — Opus with the 1M context window). |
| `effortLevel` | Default reasoning effort (`high`). |
| `alwaysThinkingEnabled` | Extended thinking on by default. |
| `tui` | `fullscreen` terminal UI. |
| `enabledPlugins` / `extraKnownMarketplaces` | Plugins to enable on a fresh machine, including the Firebase marketplace. |
| `permissions` | The allow/deny rules below. |

The four script paths are stored as `{{CLAUDE_DIR}}\scripts\...` and rewritten by `sync.ps1`. If you edit `settings.json` by hand, edit it here in the repo and re-run `sync.ps1` — don't edit `~/.claude/settings.json` directly, or the next sync will back it up and overwrite it.

### Permissions

Deny rules always take precedence over allow rules regardless of order, so the strategy is to allow broadly and deny the dangerous stuff explicitly. Adjust to fit your workflow.

#### Allow

| Rule | Reason |
|------|--------|
| `Read(**)` `Find(**)` `Bash(find:*)` | Claude needs to read and locate files constantly for context — restricting this just creates noise. |
| `Bash(git status:*)` `Bash(git log:*)` `Bash(git diff:*)` `Bash(git show:*)` `Bash(git ls-files:*)` `Bash(git branch:*)` | Read-only git inspection. Nothing here mutates the repo. |
| `Bash(ls:*)` `Bash(cat:*)` `Bash(head:*)` `Bash(tail:*)` `Bash(grep:*)` `Bash(rg:*)` `Bash(sed -n:*)` `Bash(echo:*)` | Read-only shell inspection. Only the `sed -n` form is allowed, so `sed -i` in-place editing still prompts. |
| `Bash(node --version:*)` `Bash(npm run build:*)` `Bash(npm test:*)` `Bash(npx tsc --noEmit:*)` `Bash(./gradlew test:*)` `Bash(./gradlew build:*)` | Build and test commands, so Claude can actually verify its work without a prompt every time. |

#### Deny

| Rule | Reason |
|------|--------|
| `Bash(rm -rf*)` `Bash(rm -fr*)` `Bash(rm -r *)` `Bash(rm -f *)` `Bash(rm --recursive*)` `Bash(rm --force*)` | Recursive and forced deletion, in every flag spelling. Plain `rm` on a single file is still allowed. |
| `Bash(sudo *)` | Blocks all privilege escalation. Claude should never need to run as root. |
| `Bash(dd *)` | Low-level disk writing that can overwrite drives or partitions with no confirmation. |
| `Bash(mkfs *)` `Bash(format *)` | Formats a filesystem — effectively wiping a disk or partition. `format` is the Windows equivalent. |
| `Bash(wget *\|bash*)` `Bash(wget *\| bash*)` `Bash(curl *\|bash*)` `Bash(curl *\| bash*)` | Blocks the pipe-to-shell pattern (`curl url \| bash`) used in supply chain attacks. Both spacings, both download tools. |
| `Bash(git push --force*)` `Bash(git push *--force*)` `Bash(git push -f*)` `Bash(git push * -f*)` | Force push rewrites remote history and can permanently destroy work for the whole team. Long and short flags, both positions. |
| `Bash(git reset --hard*)` | Discards all uncommitted changes with no recovery path. |
| `Bash(git clean -f*)` | Deletes untracked files outright — including anything not yet staged. |
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
