---
description: Draft a Decision Log entry from the current working diff (or a topic) and append it to docs/DECISIONS.md. Captures the WHY behind a change — architecture, provider, direction, or compliance calls.
argument-hint: "[optional topic/hint]   e.g. 'switched analytics to PostHog'  — omit to infer from the diff"
allowed-tools: Bash, Read, Edit
model: sonnet
---

You maintain `docs/DECISIONS.md`, the append-only Decision Log for the Execute project. Your job: turn a real change into one tight entry that captures the *reasoning git can't hold*. Read-mostly — you only ever Edit `docs/DECISIONS.md`.

## 1. Gather evidence (don't guess)
- Read the top ~40 lines of `docs/DECISIONS.md` to match the exact format, tone, and the newest-on-top ordering.
- Inspect the change:
  - `git status --short` and `git diff` (unstaged + `git diff --cached`) for working changes.
  - If the diff is empty, look at the last commit: `git show --stat HEAD` and `git log -1 --format='%ad %h %s' --date=short`.
- If `$ARGUMENTS` is provided, treat it as the topic/hint and anchor the entry on it; still ground every claim in the diff/commit.
- Get today's date: `date +%Y-%m-%d`. Get the relevant commit hash if one exists.

## 2. Decide whether it even warrants an entry
The log is for **decisions**, not mechanics. Warrants an entry: provider swap, architecture choice, scope/direction pivot, a compliance call, a dependency added/dropped for a reason, reversing a prior decision.
Does NOT: typo/format/lint fixes, dependency bumps, pure refactors with no behavioral or directional meaning.
- If it doesn't warrant one, say so in one line and stop — do not edit the file.
- If a prior entry is being **reversed**, find it, append `**Status:** superseded by → <today's title>` to it (don't delete it), then write the new entry.

## 3. Write the entry
Match the template already in the file's header. Keep it to the point — context in 1–2 lines, and make **Why** the load-bearing field (the reasoning, the failure mode avoided, the tradeoff). Fill **Rejected** only if a real alternative was weighed. Pick one **Type:** `architecture | provider | direction | compliance | dependency`.

```markdown
## YYYY-MM-DD — <short title>
**Type:** <type> · **Status:** active
**Context:** <the situation forcing a choice>
**Decision:** <what was decided>
**Why:** <reasoning git can't hold>
**Rejected:** <alternative + why not> (only if real)
**Touches:** <files/areas> · **Commit:** <hash> (if one exists)
```

## 4. Insert and confirm
- Insert **directly below** the `---` separator that ends the file header, **above** the current newest entry (newest-on-top). Use Edit; do not reorder or alter existing entries (except a supersede note when reversing).
- After editing, print the entry you added and a one-line note on where it landed. Remind the user it's drafted from your reading — they should tweak the **Why** if you missed intent.
