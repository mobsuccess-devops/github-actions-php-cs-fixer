---
name: branch-commit-pr-ticket
version: 2.2.0
description: Full automated workflow from local changes to a pull request with Linear ticket creation, optimized for latency. Analyzes git diff, creates branch, commits, pushes, creates a Linear ticket with a French title (sub-issue of a `SUP-XXXX` support issue when one is given), and opens a PR linked to the ticket — in 4 round-trips, by batching every git/gh command into one call per wave, keeping Linear MCP calls to 2, and taking its Linear config solely from the `## Linear` section already in context (it does not read `.mobsuccess.yml`).
---

# Branch → Commit → Linear Ticket → PR

Four waves, batched: branch, commit and push; create the Linear ticket; open the PR; link it back and lock the status.

## Description (optional)

$ARGUMENTS

## Support issue (optional)

If the description above contains a **`SUP-<digits>`** reference, the ticket created in wave 2b becomes a **sub-issue of it** (`parentId`). Only the literal `SUP-` prefix counts; any other identifier is just text.

- **Never validate it.** No `get_issue`, no `list_issues` — pass the identifier straight to `save_issue` and let the server resolve it. That is what keeps this skill at 2 Linear calls.
- **The child keeps its own config.** Team, project, status and labels stay the ones resolved below — it does **not** inherit the support issue's team or project. A `SUP-…` parent on another team is normal and fine.
- **The support issue is never touched.** No status change, no label, no PR link on it. Wave 4 links the PR to the child only.
- **`SUP-…` must not appear in the branch name, the PR title, or the PR body.** The GitHub↔Linear integration scans all three and would attach the PR to the support issue. Mentioning it inside the Linear child's `description` is safe — that is a Linear-side backlink only.
- Strip the reference before inferring anything: the remaining text of the description drives the commit message, the French title and the PR body, so `SUP-1234` never leaks into them.

## Fully automatic

Never ask the user anything — not for type, scope, description, priority, or estimate. Infer everything from the diff and proceed straight through.

## The one rule

**A round-trip is the unit of cost.** Shell commands are free to batch (any number in one `Bash` call); Linear MCP calls are not (one call, one round-trip, no batching). So:

- Every git/gh command for a wave goes in **one** `Bash` call — including any file you need to peek at. Never follow a wave with a stray `Read`.
- Exactly **2** Linear MCP calls: create the issue, then link+lock its status. A third is allowed only to repair a failure.
- Never call `get_team`, `get_project`, `list_issue_statuses`, `list_issue_labels`, `list_users`, or `get_user` on the happy path; the only exception is the [Recovery](#recovery-on-error-only) table, after a `save_issue` has failed. `save_issue` accepts **names** for `team`, `project`, `state`, and `labels`, and `"me"` for `assignee` — it resolves them server-side.
- Never verify with `get_issue`; `save_issue` returns the saved issue, so read its response instead.

Four waves, in order. Waves 2a/2b are emitted in the **same message** so they run concurrently.

> **Why not a CLI instead of the MCP?** `lnr` (linear-cli) is not a substitute: it needs `linear-api-key` in `~/.mobsuccess.yml` (crashes at startup without it), it prompts interactively, and it exposes fewer fields than `save_issue`. Do not route ticket creation through it.

---

## Wave 1 — Recon (1 `Bash` call)

```bash
echo "=== BRANCH ==="; git branch --show-current
echo "=== STATUS ==="; git status --porcelain
echo "=== UNTRACKED ==="; git ls-files --others --exclude-standard
echo "=== STAT ==="; git diff HEAD --stat
echo "=== DIFF ==="; git diff HEAD -- . ':!*.lock' ':!*-lock.json' ':!*.min.*' ':!*.snap' | head -c 60000
echo "=== NEW FILES ==="; git ls-files --others --exclude-standard \
  | grep -Eiv '(^|/)\.env|\.(pem|key|p12|pfx|log|tmp|bak)$|secret|credential|password|token' \
  | head -3 | while read -r f; do grep -Iq . "$f" 2>/dev/null && { echo "--- $f"; head -c 2000 "$f"; }; done
echo "=== PR TEMPLATE ==="; cat .github/pull_request_template.md 2>/dev/null || echo "(none)"
echo "=== DEFAULT ==="; git fetch --quiet origin; DEFAULT=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name); echo "$DEFAULT"
echo "=== BASE CANDIDATES ==="; CUR=$(git branch --show-current)
OPEN=$(gh pr list --state open --limit 200 --json headRefName --jq '.[].headRefName')
CANDS=$(git for-each-ref --merged HEAD --format='%(refname:short)' refs/remotes/origin \
  | grep -Ev "^origin(/(HEAD|main|master|preprod|prod|$DEFAULT))?$" | grep -vxF "origin/$CUR" \
  | while read -r r; do printf '%s\n' "$OPEN" | grep -qxF "${r#origin/}" || continue
      n=$(git rev-list --count "origin/$DEFAULT..$r"); [ "$n" -gt 0 ] && echo "$n ${r#origin/}"; done | sort -rn); echo "$CANDS"
TOP=$(printf '%s\n' "$CANDS" | awk 'NR==1 {print $2}')
OFF=$(printf '%s\n' "$CANDS" | awk 'NR>1 {print $2}' | while read -r b; do git merge-base --is-ancestor "origin/$b" "origin/$TOP" || echo "$b"; done)
echo "=== DETECTED BASE ==="; if [ -n "$TOP" ] && [ -z "$OFF" ]; then echo "$TOP"; else echo "$DEFAULT"; fi
```

That block is everything the whole workflow needs to read. `git diff HEAD` covers staged + unstaged at once; lockfiles and generated files are excluded so the 60 KB cap is spent on signal. If it still truncates, reason from `STAT` plus what you saw — never re-run it uncapped, and never `Read` a file the block already previewed.

`git status --porcelain` and `git ls-files --others` overlap but are not redundant: status collapses a new directory into a single `?? dir/` line, and the screen below needs per-file granularity. The `NEW FILES` preview deliberately re-applies the secret patterns and skips binaries — it runs _before_ the screen below, so it must never be the thing that prints a `.env` into the transcript.

`BASE CANDIDATES` lists the branches with an **open PR** whose tip is already in HEAD's history and ahead of the default branch, nearest parent first — that is how a **stacked** branch (cut from another feature branch) is detected. `DETECTED BASE` is the nearest one only when the candidates form a single chain; an ambiguous history (e.g. HEAD merged an unrelated feature branch) falls back to `DEFAULT` rather than guessing.

**Resolve `BASE`** (the PR's target): a base named in the description (`base: feat/x`, `sur feat/x`, `sous-branche de feat/x`, `into master`…) → else `DETECTED BASE`. `BASE` is **stacked** unless it is `main`, `master`, `preprod`, `prod` or a `hotfix/*` branch; a stacked base changes the branch name (see [Reference](#reference)).

**Stop conditions** — check both before anything else:

- `STATUS` and `UNTRACKED` both empty → print `Nothing to commit — working tree clean.` and exit. No branch, commit, ticket, or PR.
- Any untracked file matching a suspicious pattern → stop the whole workflow, name the files, suggest `.gitignore` or manual review. Patterns:
  - Secrets: `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*secret*`, `*credential*`, `*password*`, `*token*`
  - Build/cache: `*.pyc`, `__pycache__/`, `node_modules/`, `dist/`, `build/`, `.cache/`
  - Editor/OS: `.DS_Store`, `Thumbs.db`, `*.swp`, `*.swo`, `*~`
  - Debug/temp: `*.log`, `*.tmp`, `*.bak`, `debug.*`, `test-output*`

**Then infer everything, with no further calls** — type, scope, description, priority, estimate, branch name, labels (see [Reference](#reference)), and the Linear config below.

### Linear config — one source, already in your context

**Read the `## Linear` section of `CLAUDE.md` / `AGENTS.md`.** It is already in your system prompt, so this costs nothing: no file to open, no YAML to parse, no `.mobsuccess.yml`. Anything the user said earlier in the conversation overrides it; anything neither provides falls back to the default below.

It looks like this, and every line maps to one `save_issue` argument:

```markdown
## Linear

- Team: FT Tech Foundation (ID: `ad239236-…`)
- Project: Tooling for Engs
- Status: QA Accepted
- Label Business Unit: MOBSUCCESS Group (ID: `fd0c2ac8-…`)
- Label Teams: Experiences (ID: `7160507e-…`)
- Label Type: Improvement 🛠️ (ID: `4d7c046c-…`)
```

Reading rules:

- **Team / Project / Status** → the `team`, `project`, `state` arguments.
- **Every `Label …:` line** → one entry in `labels`. Send them all; there is no fixed list of which label kinds may appear.
- **A pinned `Label Type:` wins over the inferred type label.** With no such line, infer it from the change (`feat` → `Feature ✨`, `fix` → `Bug 🐞`, else `Improvement 🛠️`).
- **At most one label per Linear label group.** Linear allows a single label from a group (e.g. **Teams**: `Core`, `Experiences`, …) and rejects the call with a 400 (_"The label 'Core' is in the same group as 'Experiences'"_). If the section lists two labels of one group, send only the first and say so in the output; a pinned `Label Type:` already replaces the inferred type label.
- **When a UUID is given, send the UUID, not the name.** It is unambiguous, so it removes the only real failure mode of name resolution — two labels differing solely by case or emoji.
- **Priority and estimate are never configured** — always infer them.

Defaults when the section is absent or silent on a field: team `FT Tech Foundation`, project `FT Tech - RUN`, status `QA Accepted`, labels `MOBSUCCESS Group` + the inferred type label. **Say so in the final output** — a repo that keeps its Linear config only in `.mobsuccess.yml` will land here silently, and the resulting ticket will carry the wrong team or project.

> **`.mobsuccess.yml` is never read** (`linear.cli_defaults.*`, `linear.team_identifier`, `linear.linear_issue_required`, …). If a repo's Linear config lives only in that file, the workflow will fall back to the defaults below — copy the config into a `## Linear` section of `CLAUDE.md` / `AGENTS.md` to fix that.

To skip Linear entirely, the user says so, or the `## Linear` section says tickets aren't required: then skip waves 2b and 4, and create the PR with no ticket reference anywhere.

---

## Wave 2 — Commit + push ∥ Create ticket (1 `Bash` + 1 MCP, one message)

### 2a. `Bash` — branch, stage, commit, push

```bash
set -e
CURRENT=$(git branch --show-current)
BASE='<base>'                   # resolved in wave 1
TARGET='<branch-name>'          # <type>/<kebab-description>, or <BASE>--<kebab-description> when stacked — see Reference
VALID='^(hotfix|feat|fix|chore|docs|refactor|test|revert|ci|perf|style|build|change|remove|poc)/[a-z][a-z0-9._-]*$'
is_default() { case "$1" in ''|main|master|preprod|prod) return 0 ;; *) return 1 ;; esac; }
case "$BASE" in main|master|preprod|prod|hotfix/*) STACKED= ;; *) STACKED=1 ;; esac
bad_name() {
  ! printf '%s' "$1" | grep -Eq "$VALID" && return 0
  [ -n "$STACKED" ] && case "$1" in "$BASE"--?*) return 1 ;; *) return 0 ;; esac
  return 1
}

if [ "$CURRENT" != "$TARGET" ] && { is_default "$CURRENT" || bad_name "$CURRENT"; }; then
  if ! is_default "$CURRENT" && [ "$CURRENT" != "$BASE" ] && ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git branch -m "$TARGET"      # unpushed junk branch (worktree-feat+…, codex/…, unprefixed stacked child): rename in place
  else
    git checkout -b "$TARGET"    # default, detached, stacked parent, or already-pushed branch: branch off HEAD
  fi
fi

git add -A
git commit -F - <<'EOF'
<type>(<scope>): <description>

Co-authored-by: <your platform identity — see Reference>
EOF
git push -u origin "$TARGET"
git log -1 --format='%h %s'
```

Both branches of the `if` preserve the working tree and the index. `git add -A` includes untracked files (already screened in wave 1); `.gitignore` still applies.

### 2b. `save_issue` — create the ticket (no `id`, names only)

```
title:       <French infinitive title, ≤ 17 words>
description: <Problem / Solution / Changes / Impact>
team:        <team>          project: <project>       state: <status>
assignee:    "me"            priority: <1-4>          estimate: <Fibonacci — mandatory>
labels:      [<every label from the ## Linear section — UUID when given, else name>]
parentId:    <SUP-XXXX — only when the description carried one; omit otherwise>
```

`labels` replaces the whole set, so pass the complete list here, including the type label, with at most one label per group. Never pass empty strings for labels the section doesn't mention — just leave them out.

**If the call fails on the parent** (unknown or inaccessible `SUP-XXXX`, so nothing was created): re-send the exact same `save_issue` **without** `parentId`, and say so loudly in the final output — the ticket must exist, an unresolvable support reference must never abort a workflow whose commit is already pushed. Per "The one rule" this is a failure repair, not a third routine call.

Two things to take from the response, at no extra cost: **`<ISSUE_ID>`** is its `identifier` (e.g. `FTTECH-123`) — reuse that exact string in waves 3 and 4 — and a glance at its `project` and `labels` fields confirms the names resolved. If either came back empty, one `save_issue` with `id` re-sends the missing field; that is the failure repair the budget allows, not a routine check. A label repair re-sends the **whole** set, built from the labels the response shows plus the missing ones — keeping a label the ticket already has in a group instead of adding a second one from that group.

**Title** — actionable verb in the infinitive, in French: _"Ajouter un endpoint pour récupérer les utilisateurs actifs"_, _"Corriger le bug d'authentification sur la page login"_.

**Description**:

```markdown
## Problem

<what was broken/missing/inefficient — inferred from the diff>

## Solution

<the approach taken in the code>

## Changes

- <file>: <what changed>

## Impact

- <technical impact>
- <business impact if any>
```

---

## Wave 3 — Create the PR (1 `Bash` call)

```bash
gh pr create --base '<BASE>' --title '<type>(<scope>): <description> [<ISSUE_ID>]' --body "$(cat <<'EOF'
## What Does It Do?

<brief description>

## Context

<why this change, what it solves>

## Test Plan

- [ ] <how to verify>
EOF
)"
```

`gh pr create` prints the PR URL on stdout — no `gh pr view` needed. `--base` is the `BASE` resolved in wave 1 — the parent branch for a stacked PR, the default branch otherwise. Title ≤ 150 chars, ticket ID in brackets (`feat(user): add profile endpoint [FTTECH-123]`). Use the repo template from wave 1 if there was one. Omit the `[<ISSUE_ID>]` suffix when Linear was skipped.

`<ISSUE_ID>` is always the **created** ticket, never the support issue: no `SUP-…` string anywhere in the title or the body, or the integration attaches this PR to the support issue too.

---

## Wave 4 — Link the PR and lock the status (1 `save_issue`)

The GitHub↔Linear integration flips the ticket to "Development In Progress" the moment it sees the PR. Rather than polling for that, attach the link and re-assert the status in the **same** call, after the integration has already had its chance:

```
id:    <ISSUE_ID>
links: [{ url: "<pr_url>", title: "PR #<number>" }]
state: "<status>"
```

No `labels` here: the set from 2b stands, and re-sending it could collide with a label added since. `state` goes by **name** — Linear resolves it within the ticket's own team.

Read the state off the response. If it came back wrong, send **one** corrective `save_issue` with `state` — that is the whole budget, and losing the race here is common enough not to be worth explaining. If the second attempt also loses, stop and tell the user:

> Status keeps reverting to "Development In Progress" — set it to "\<status\>" manually in Linear, or adjust the GitHub-Linear integration rules.

---

## Output

```
## Workflow Complete

### Git
- **Branch**: `<branch_name>`
- **Commit**: <short_hash> - <commit_message>

### Pull Request
- **Title**: <pr_title>
- **URL**: <pr_url>

### Linear Ticket
- **Status**: <status>
- **Issue**: <issue_identifier> - <title>
- **URL**: <linear_url>
- **Project**: <project>
- **Parent**: <SUP-XXXX> (omit the line when no support issue was given)
- **Priority**: <priority> | **Estimate**: <estimate>
- **Config**: `## Linear` section | defaults (no section found)
```

When the parent could not be resolved, replace that line with a warning instead of dropping it:

```
- ⚠️ **Parent**: `SUP-XXXX` could not be resolved — ticket created without a parent, link it manually in Linear
```

The `Config` line is not decoration: when it reads `defaults`, the ticket may have landed on the wrong team or project, and the user needs to see that without opening Linear.

---

## Recovery (on error only)

Per "The one rule": these are repairs, so they only ever run after a `save_issue` has actually failed.

| Failure          | Fix (one extra call at most)                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------- |
| Unknown label    | `list_issue_labels` **filtered by `name`** (plus `team`) — never a paginated sweep. Drop the label if truly absent. |
| Unknown project  | `list_projects` with `query`, else fall back to `FT Tech - RUN`                                                     |
| Unknown team     | Fall back to `FT Tech Foundation` and retry                                                                         |
| Unknown state    | `list_issue_statuses` for the ticket's own team (never another team's ID), else omit `state` and fix it in wave 4   |
| Unknown parent   | Re-send `save_issue` without `parentId`, then warn loudly in the output. Never abort over it                        |
| Nothing persists | The Linear MCP may be disabled — ask the user to check it's enabled                                                 |

---

## Reference

**Type & labels** — `feat` → `Feature ✨`; `fix` → `Bug 🐞`; `chore`/`refactor`/`style`/`test`/`docs` → `Improvement 🛠️`. Emoji are part of the label name.

**Branch** — `<type>/<kebab-description>` (type among `chore|fix|feat|refactor|style|test|docs`), and it must match CI's regex `^(hotfix|feat|fix|chore|docs|refactor|test|revert|ci|perf|style|build|change|remove|poc)/[a-z][a-z0-9._-]*$`. Never `fttech-123-…`, never a `worktree-…`/`codex/…` prefix.

**Stacked branch** — when the PR's base is not `main`/`master`/`preprod`/`prod`/`hotfix/*`, CI ([`lib/actions/pullRequest.js`](https://github.com/mobsuccess-devops/github-actions-mobsuccess/blob/master/lib/actions/pullRequest.js)) requires the head to be `<base>--<kebab-description>`, still with a single `/`: base `feat/dbt-unit-tests` → `feat/dbt-unit-tests--add-model-tests`, never `feat/add-model-tests` nor `feat/dbt-unit-tests--feat/…`. Stacks nest (`feat/a--b--c`). If a PR was already opened with the wrong name (_"As this pull request is based on “feat/x”, its name should start with “feat/x--”"_), don't rename the pushed branch — push a correctly named branch from HEAD, open a new PR on the same base, close the old one; or, if the PR was meant for the default branch, `gh pr edit <n> --base <default>`.

**Commit** — conventional subject plus a `Co-authored-by:` trailer using **your platform's identity** (Cursor → `Cursor <cursoragent@cursor.com>`; Claude/Codex/Copilot → check your platform's docs), so the AI shows up as co-author on GitHub.

**Priority** — 1 Urgent (security, prod blocker) · 2 High (critical bug, data loss) · 3 Medium (default) · 4 Low (nice-to-have).

**Estimate (Fibonacci, mandatory)** — 1: <20 lines / 1-2 files · 2: 20-50 / 3 · 3: 50-150 / 4-5 · 5: 150-300 / 6-9 · 8: 300-500 / 10-14 · 13: 500-1000 / 15-19 · 21: 1000+ / 20+ (suggest splitting).

**Labels sent** — every `Label …:` line of the `## Linear` section, plus the inferred type label when that section pins none. With no section at all: `MOBSUCCESS Group` + the inferred type label.

**PR not mergeable?** The ticket status must match the resolved status — that's wave 4.
