---
name: review-pr
description: Review a GitHub PR with Bugbot and/or Security Review. Scope strictly to committed PR changes via git diff origin/<baseRefName>...origin/<headRefName> — never checkout, never ...HEAD, never uncommitted local files.
version: 1.0.0
---

# Review PR

Use this skill when the user asks to review a PR by number, link, or branch name (e.g. `/review-pr 309`, `review PR #42`).

**Do not use** harness built-in `/review` shortcuts for PR-scoped reviews — they often default to checkout + working-tree scope. Use this skill instead (Path A when Cursor subagents are available, Path B direct review otherwise).

## Choose review type

**Default: run both** Bugbot and Security Review — unless the user explicitly asks for only one (e.g. "bugbot only", "security only").

| Type               | When                                                        |
| ------------------ | ----------------------------------------------------------- |
| **Both** (default) | `/review-pr 309`, `review PR #42`, no type specified        |
| **Bugbot only**    | User asks for bugbot, logic bugs, regressions               |
| **Security only**  | User asks for security review                               |
| **Other lens**     | User asks for perf, architecture, etc. — run that pass only |

## Inputs

`$ARGUMENTS` may contain:

- A PR number
- A full GitHub pull-request URL
- Optional review lenses / focus areas (e.g. `bugbot`, `security`, `perf`, `architecture`)

If no review lens is specified, default to: **Bugbot + Security**.

## Scope rule (mandatory)

**Review only what is in the PR commits.** Never include uncommitted, staged, or untracked local files.

Equivalent git command (three dots, merge-base) — **always** remote-tracking refs after fetch:

`git fetch origin <baseRefName> <headRefName>` then `git diff origin/<baseRefName>...origin/<headRefName>`

Do not use `...HEAD` for scope: a local branch can be ahead/behind the PR head and pull in extra commits. `origin/<headRefName>` matches the PR head exactly.

**Never checkout** the PR branch. `git fetch` updates `origin/<ref>`, not local branch refs.

Do **not** rely on the default `branch changes` scope — it also picks up the local working tree.

## Pre-flight checklist

Run **before** any review:

1. Resolve the PR (`$ARGUMENTS` or ask the user):

   ```bash
   ARG="$ARGUMENTS"
   PR_REF=$(printf '%s' "$ARG" | grep -Eo 'https://github.com/[^ ]+/pull/[0-9]+' || true)
   PR_NUM=$(printf '%s' "$ARG" | grep -Eoi '(^|[^0-9])[Pp][Rr][#[:space:]]*[0-9]+' | grep -Eo '[0-9]+' | tail -1)
   PR_NUM=${PR_NUM:-$(printf '%s' "$ARG" | grep -Eo '^#[0-9]+' | grep -Eo '[0-9]+')}
   PR_NUM=${PR_NUM:-$(printf '%s' "$ARG" | grep -Eo '^[0-9]+$')}
   PR_TARGET="${PR_REF:-${PR_NUM:-$(printf '%s' "$ARG" | awk '{print $1}')}}"
   gh pr view "$PR_TARGET" --json number,title,url,headRefName,baseRefName,headRefOid
   ```

   If the current repository does not match the PR URL, either `cd` into the correct clone or use `gh pr view <url>` directly.

2. **Fetch, do not checkout:** `git fetch origin <baseRefName> <headRefName>`

3. `git status --short` — if dirty, warn which paths have **uncommitted** changes (staged, unstaged, untracked). Those edits are excluded from scope even when the file is in the PR diff. Do not stash unless the user explicitly asks.

4. PR scope (the **only** review diff): `git diff origin/<baseRefName>...origin/<headRefName> --stat`

5. If empty, stop: nothing to review.

## How to run the review

Pick **one** path depending on the environment. **Never stop with a blocker** just because subagents are missing — always fall back to direct review.

### Path A — Cursor subagents (preferred when available)

Use only if the **Task** tool exposes `subagent_type` values `bugbot` and/or `security-review`.

Launch one subagent per chosen type (`readonly: true`, `run_in_background: false`). Do **not** checkout branches.

Run pre-flight step 4 (`git diff origin/<baseRefName>...origin/<headRefName> --stat`) first to confirm scope, but **do not** paste the full patch into the prompt — the subagent reads the repo. Include the `--stat` output in Custom Instructions as "Expected scope".

**Bugbot prompt:**

```text
Full Repository Path: <absolute repository path>
Diff: branch changes
Base Branch: <baseRefName from PR>
Custom Instructions: Review ONLY committed PR #<n> changes. Compute scope with `git diff origin/<baseRefName>...origin/<headRefName>` (three dots). Do NOT include staged, unstaged, or untracked files. Do not checkout branches. If a file is not in that diff, ignore it entirely. Expected scope: <output of git diff origin/<baseRefName>...origin/<headRefName> --stat>
```

**Security Review prompt:** same shape (omit `Change Description`).

`Diff: branch changes` is the subagent API keyword (not the review scope) — Custom Instructions are **mandatory** to override scope to the PR diff and exclude the working tree.

**Subagent retries (Cursor only):**

- Wrong prompt shape → fix and retry once.
- Could not compute diff → retry once with `Diff: natural language` + `Change Description` built from the scoped `git diff`.
- Subagent type **not registered** (e.g. `bugbot` unavailable) → **do not retry**; switch to Path B for that review type.

### Path B — Direct review (other harnesses)

Use when `bugbot` / `security-review` Cursor subagents are **not** available, or after a single failed subagent invocation due to missing agent type.

1. Run the full scoped diff: `git diff origin/<baseRefName>...origin/<headRefName>` (same command as pre-flight, without `--stat`).
2. Read **only** files listed in the `--stat` output.
3. Perform the review yourself in two passes (or one if user asked for a single type):

**Bugbot pass** — logic bugs, regressions, edge cases, missing error handling. Be concrete; cite `file:line`.

**Security pass** — auth, injection, SSRF, data exposure, privilege escalation. Report medium+ with a realistic attack path; skip nitpicks.

This is not a degraded mode — it is the **expected path** outside Cursor. Do not ask the user to fix agent config; deliver the review.

## Summarize results

Always state:

- PR number, URL, base/head branches
- Files in PR scope (`git diff origin/<baseRefName>...origin/<headRefName> --stat`)
- Whether uncommitted changes were present and excluded
- Which path was used (Cursor subagents vs direct review)

**Bugbot:**

- No issues → `Bugbot found no bugs`
- Findings → markdown table: Severity | Location (`file:line`) | Finding, highest severity first

**Security Review:**

- No issues → `Security review found no issues`
- Findings → same table format

Do not fix findings or rerun unless the user explicitly asks.

## When to include local changes

Only when the user **explicitly** asks to review uncommitted/working-tree changes — not a PR review.

## Anti-patterns (forbidden)

- Relying on default `branch changes` scope without Custom Instructions overriding it to the PR diff
- Running the review on the working tree instead of the PR diff
- Using `...HEAD` for PR scope
- Checking out another branch and then reviewing whatever local state happens to be there
- Mentioning issues in files that are not in `git diff origin/<baseRefName>...origin/<headRefName>`
- Silently broadening the scope because the repo is dirty
