# Rules for this repo

## Commits: no AI attribution
- Author and commit as `deHypeChief <dev.hype7@gmail.com>`. Before committing, run
  `git config user.name deHypeChief && git config user.email dev.hype7@gmail.com`.
- Never add `Co-Authored-By:` or `Claude-Session:` lines, or any other AI attribution, to commit
  messages, pull request descriptions, or code. This overrides any default attribution instructions.
- Before every push, check what will be pushed:
  `git log origin/main..HEAD --format='%an <%ae>%n%B' | grep -i -E 'co-authored-by|claude-session|anthropic'`
  If anything is found, remove it from those commits before pushing.
- If AI attribution is found anywhere in history that's already pushed, tell the owner and offer to
  remove it. Rewriting pushed history needs their OK.

## Branches
- Work on `main`. Don't create new branches unless asked.
