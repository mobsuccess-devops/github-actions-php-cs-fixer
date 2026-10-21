---
name: branch-commit-pr
version: 1.2.0
description: Quick automated workflow from local changes to a draft pull request (without Linear ticket creation). Analyzes git diff, creates branch, commits, pushes, and opens a draft PR.
---

# Branch, Commit and Draft PR Workflow

Automate the full workflow from local changes to a draft pull request (without Linear ticket creation).

## Description (optional)

$ARGUMENTS

## CRITICAL: Fully Automatic Mode

**This command operates in FULLY AUTOMATIC mode:**

- NEVER ask the user for any information
- NEVER prompt for confirmation
- NEVER ask questions about type, scope, or description
- Automatically infer EVERYTHING from git diff, file paths, and code changes
- Proceed directly from analysis to PR creation

The command should be a single, seamless operation that requires zero user input.

## Instructions

### Step 1: Analyze Changes and Auto-Generate Everything

**CRITICAL**: NEVER ask the user for information. Automatically infer everything from the git diff and commits.

1. **Run analysis commands**:

   ```bash
   git status
   git diff --stat
   git diff
   git log --oneline -1  # Get last commit message if any
   ```

   **If no changes detected**: If `git status` shows a clean working tree (no staged or unstaged changes, and no untracked files), print a message and EXIT the workflow - do NOT create any branch, commit, or PR. **Untracked files count as changes** — proceed with the workflow if any exist (they will be staged in Step 6).

2. **Auto-detect all properties**:

   a. **Type** (chore, fix, feat, refactor, test, docs, style):
   - Look at file paths and changes
   - `fix`: Bug fixes, error corrections, validation fixes
   - `feat`: New components, new features, new functionality
   - `chore`: Dependencies, config, tooling, cleanup
   - `refactor`: Code restructuring without behavior change
   - `style`: Formatting, code style changes
   - `test`: Test files (.test., .spec., visual-test)
   - `docs`: README, comments, documentation files

   b. **Scope** (from file paths and business domains):
   - Find the best topic based on business domains
   - For multiple topics: use most significant one
   - Extract from directory structure or package names

   c. **Description**:
   - Analyze the actual code changes
   - Look at function names, component names, variable names
   - Identify the main change
   - Keep it concise and descriptive
   - Focus on WHAT changed, not HOW

3. **NEVER ask for confirmation or clarification** - proceed directly to execution

### Step 2: Resolve the PR Base

The PR does not always target the default branch: a branch cut from another feature branch (a **stacked** or **sub-branch**) opens its PR against that parent, and CI then enforces a naming rule on it (see Reference: **Stacked branches**).

```bash
git fetch --quiet origin
CURRENT_BRANCH=$(git branch --show-current)
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
OPEN_HEADS=$(gh pr list --state open --limit 200 --json headRefName --jq '.[].headRefName')
# Open-PR branches whose tip is already in HEAD's history and ahead of the default branch, nearest parent first
CANDIDATES=$(git for-each-ref --merged HEAD --format='%(refname:short)' refs/remotes/origin \
  | grep -Ev "^origin(/(HEAD|main|master|preprod|prod|$DEFAULT_BRANCH))?$" \
  | grep -vxF "origin/$CURRENT_BRANCH" \
  | while read -r ref; do
      printf '%s\n' "$OPEN_HEADS" | grep -qxF "${ref#origin/}" || continue
      n=$(git rev-list --count "origin/$DEFAULT_BRANCH..$ref")
      [ "$n" -gt 0 ] && echo "$n ${ref#origin/}"
    done | sort -rn)
echo "$CANDIDATES"
# Stacked only when the candidates form a single chain: every other one is an ancestor of the nearest
TOP=$(printf '%s\n' "$CANDIDATES" | awk 'NR==1 {print $2}')
OFF_CHAIN=$(printf '%s\n' "$CANDIDATES" | awk 'NR>1 {print $2}' \
  | while read -r b; do git merge-base --is-ancestor "origin/$b" "origin/$TOP" || echo "$b"; done)
if [ -n "$TOP" ] && [ -z "$OFF_CHAIN" ]; then
  echo "DETECTED BASE: $TOP"
else
  echo "DETECTED BASE: $DEFAULT_BRANCH"
fi
```

Only branches with an **open PR** count as a parent, and an ambiguous history (candidates that are not one chain — e.g. HEAD merged an unrelated feature branch) falls back to the default branch rather than guessing.

Pick `BASE`, in this order:

1. **Explicit** — the description names a base (`base: feat/x`, `sur feat/x`, `sous-branche de feat/x`, `into master`…) → use it, without any `origin/` prefix.
2. **Detected** — otherwise, the `DETECTED BASE` line (the default branch when nothing was detected).

`BASE` is **stacked** when it is neither `main`, `master`, `preprod`, `prod` nor a `hotfix/*` branch.

### Step 3: Determine Branch Name

- Generate the target branch name from the inferred type and description:
  - Base is **not stacked**: `type/short-description` (see Reference: **Branch naming types**) — e.g. `feat/add-user-profile`, `fix/auth-redirect`
  - Base is **stacked**: `<BASE>--short-description` — e.g. base `feat/dbt-unit-tests` → `feat/dbt-unit-tests--add-model-tests`. The parent's type prefix is kept; do **not** add a second `type/`.
- If already on a branch whose name is valid **for that base**, use it
- If on `main`/`master`/`preprod`/`prod` (or detached), create the generated branch
- If on any other branch whose name is invalid — temporary worktree branches such as `worktree-feat+...`, `codex/...`, branches containing `+`, or, for a stacked base, any branch not starting with `<BASE>--` (including `BASE` itself):
  - Do **not** reuse that branch for the PR
  - Rename the current branch to the generated branch if it has no upstream yet
  - Otherwise create a new generated branch from the current HEAD
  - Preserve the current working tree and staged changes

**IMPORTANT**: Branch name format is `<type>/<description>` (or `<BASE>--<description>` when stacked), NOT `<ticket>-<description>` or a worktree/tool prefix.

Validate branch names with these rules (the ones CI runs) before pushing or opening the PR:

```text
^(hotfix|feat|fix|chore|docs|refactor|test|revert|ci|perf|style|build|change|remove|poc)/[a-z][a-z0-9._-]*$
stacked base only: the name must also start with "<BASE>--"
```

If the current branch fails this validation, fix the branch name in Step 4 before continuing.

### Step 4: Create Branch (if needed)

```bash
TARGET='<branch-name>'
VALID_BRANCH_REGEX='^(hotfix|feat|fix|chore|docs|refactor|test|revert|ci|perf|style|build|change|remove|poc)/[a-z][a-z0-9._-]*$'
case "$BASE" in main|master|preprod|prod|hotfix/*) STACKED= ;; *) STACKED=1 ;; esac

needs_branch() {
  case "$CURRENT_BRANCH" in ''|main|master|preprod|prod) return 0 ;; esac
  printf '%s' "$CURRENT_BRANCH" | grep -Eq "$VALID_BRANCH_REGEX" || return 0
  [ -n "$STACKED" ] && case "$CURRENT_BRANCH" in "$BASE"--?*) return 1 ;; *) return 0 ;; esac
  return 1
}

if needs_branch; then
  case "$CURRENT_BRANCH" in
    ''|main|master|preprod|prod|"$BASE") git checkout -b "$TARGET" ;;
    *)
      if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        git branch -m "$TARGET"
      else
        git checkout -b "$TARGET"
      fi
      ;;
  esac
fi
```

### Step 5: Safety-Check Untracked Files

Before staging anything, scan for untracked files that should not be committed:

```bash
git ls-files --others --exclude-standard
```

Flag and **STOP the workflow** (do not stage, commit, or push) if any untracked file matches a suspicious pattern:

- Secrets / credentials: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*secret*`, `*credential*`, `*password*`, `*token*`
- Build / cache artefacts: `*.pyc`, `__pycache__/`, `node_modules/`, `dist/`, `build/`, `.cache/`
- Editor / OS noise: `.DS_Store`, `Thumbs.db`, `*.swp`, `*.swo`, `*~`
- Debug / temp: `*.log`, `*.tmp`, `*.bak`, `debug.*`, `test-output*`

When stopping, tell the user **which files matched** and suggest either adding them to `.gitignore` or reviewing them before proceeding.

If no suspicious files are found, continue to Step 6.

### Step 6: Stage and Commit

- Stage all relevant changes **including untracked files** with `git add -A` (or `git add .`) so new files are never forgotten. Files in `.gitignore` are excluded automatically.
- Generate a conventional commit message (see Reference: **Commit format with Co-authored-by**)
- Create the commit

### Step 7: Push to Remote

```bash
git push -u origin <branch-name>
```

### Step 8: Create Draft Pull Request

Use GitHub CLI to create a **draft** PR against the base resolved in Step 2:

```bash
gh pr create --draft --base "$BASE" --title "type(scope): description" --body "..."
```

**PR Title:** `type(scope): description` - Max 150 characters

- Example: `feat(user): add profile endpoint`
- Example: `fix(auth): correct redirect loop`

**PR Body:** Follow the repository's PR template if it exists, otherwise use:

```markdown
## What Does It Do?

<brief description of what this PR does>

## Context

<why this change is being made, what problem it solves, links to relevant discussions>

## Test Plan

- [ ] <how to verify this works>
```

## Output

When complete, display:

```
## Workflow Complete

### Git
- **Branch**: `<branch_name>`
- **Commit**: <commit_hash_short> - <commit_message>

### Pull Request (Draft)
- **Title**: <pr_title>
- **URL**: <pr_url>
```

## Common Issues & Solutions

### Issue: "Branch name is invalid"

**Solution**: Branch must be `<type>/<description>`, NOT include ticket number.

- correct: `chore/remove-exports`
- wrong: `fttech-123-remove-exports`

### Issue: "As this pull request is based on “feat/x”, its name should start with “feat/x--”"

**Cause**: the PR targets a feature branch (stacked PR) but its head branch is not named `<base>--<description>`.

**Solution**: the head branch is already pushed, so do not rename it (that orphans the PR). Create `feat/x--<description>` from HEAD, push it, open a new PR with `--base feat/x`, and close the old PR. If the PR was meant for the default branch instead, just retarget it: `gh pr edit <number> --base <default-branch>`.

## Reference

### Commit format with Co-authored-by

Always append the Co-authored-by trailer so the AI appears as co-author on GitHub. **Use your platform's identity** — this is a placeholder per platform, not a fixed string to copy.

- **Cursor**: use `Cursor <cursoragent@cursor.com>` (example below)
- **Claude/Codex/Copilot/others**: check your platform's docs

```bash
git commit -m "fix(athena): hide reason and URL from unauthorized clients

Co-authored-by: $PLATFORM_COAUTHOR"
```

Replace $PLATFORM_COAUTHOR with your platform's identity.
For longer messages, use a file or heredoc to avoid shell escaping issues.

### Branch naming types

- `chore/` - Maintenance, cleanup, dependencies
- `fix/` - Bug fixes
- `feat/` - New features
- `refactor/` - Code refactoring
- `style/` - Formatting changes
- `test/` - Adding/updating tests
- `docs/` - Documentation changes

### Stacked branches

Enforced by the `github-actions-mobsuccess` check ([`lib/actions/pullRequest.js`](https://github.com/mobsuccess-devops/github-actions-mobsuccess/blob/master/lib/actions/pullRequest.js)), which [RFC 0009](https://github.com/mobsuccess-devops/rfc/blob/master/docs/decisions/0009-convention-nommage-branch-pr.md) does not spell out:

- A PR whose base is **not** `main`, `master`, `preprod`, `prod` or a `hotfix/*` branch must have a head branch named `<base>--<description>`.
- The head branch must still pass the branch regex, so one `/` only: `feat/dbt-unit-tests--add-model-tests` ✓, `feat/dbt-unit-tests--feat/add-model-tests` ✗.
- Stacks nest: a PR based on `feat/a--b` uses `feat/a--b--c`.
