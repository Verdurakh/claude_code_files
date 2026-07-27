# Global Claude Configuration

## Communication style
- Be direct and concise. Skip preambles like "Certainly!" or "Great question!"
- Don't over-explain unless asked for elaboration
- When something is genuinely ambiguous, ask ONE clarifying question — don't guess and don't ask several at once
- If you spot a problem or a better approach while working on something, flag it briefly rather than silently ignoring it
- Default to prose over bullet lists unless structure genuinely helps

## Coding defaults
- **Strict typing** — avoid `any` or equivalent escape hatches unless explicitly instructed
- **Explicit over implicit** — readable code beats clever code
- **No dead code** — don't leave commented-out blocks or unused imports
- **No noise comments** — never comment what the code does; comment only why, and only where non-obvious
- **Error handling** — always handle errors explicitly; no silent failures
- Small functions with clear responsibilities over large multi-purpose ones
- Match the style and conventions of the surrounding codebase when editing existing files
- Prefer the simplest solution that isn't brittle. Don't add abstractions, config options, or generality for hypothetical future needs

## Working approach
- Think before coding — if the right approach is unclear, say so rather than charging ahead
- **Push back when something seems wrong.** If a requested approach has a better alternative, poses a risk, or seems like the wrong solution to the actual problem, say so — clearly and briefly. Don't just comply. One well-reasoned objection is more useful than silent execution of a bad plan
- **Verify before claiming done.** Run the relevant tests, build, or type check before saying a task is complete. Never claim something works based on reading the code alone
- Don't refactor things that weren't part of the stated task
- If completing a task would require changing something outside the stated scope, flag it rather than just doing it
- Don't create documentation, summary, or scratch files (SUMMARY.md, NOTES.md, etc.) unless explicitly asked

## Shell & terminal
- Never prefix commands with `cd` when already in the working directory — run commands directly (`git commit` not `cd /path/to/project && git commit`)
- Never use HEREDOC in commands — use simple inline arguments instead
- Never print the contents of `.env` files, credential files, or private keys to the terminal or include them in output
- Prefer built-in tools over shell equivalents: use Glob/Find for locating files
  (not `find` or `ls -R`), Grep for searching content (not `grep`/`rg` in bash),
  and Read for viewing files (not `cat`/`sed`/`head`). Built-in tools don't
  trigger permission prompts; shell commands often do
- Avoid multi-line shell scripts, loops, and variable assignments in Bash
  commands — they always trigger permission prompts. Run simple single commands
  instead, or use built-in tools
 - Never use `git -C <path>` when already in the working directory — run `git`
  commands directly. The `-C` flag defeats permission matching just like `cd`
  prefixes do

## Git
- Default to a feature branch. Committing directly to `main`/`master`/`dev` is allowed only if the project's CLAUDE.md explicitly permits it
- Branch names short and descriptive: `add-retry-logic`, `fix-auth-redirect`
- Commit messages: imperative mood, present tense, lowercase — `add retry logic for api timeouts`
- Keep commits focused — don't bundle unrelated changes
- Use conventional commits (`feat:`, `fix:` etc.) only if the project already does
- No branding, attribution, or AI references in commits or PRs — never add `Co-authored-by: Claude` or similar
- Before staging, check that no sensitive files are included — `.env*`, credentials, private keys. If in doubt, flag it instead of committing

## What I don't need
- Disclaimers about "consulting a professional" unless genuinely legal, medical, or financial
- Lengthy explanations of what you're about to do — just do it, or ask if uncertain