---
description: Deep analysis of this project's Claude Code sessions. Runs the metrics engine, fans out specialist analysts in parallel, and writes a prioritized report on how to use Claude Code better and how the project is shaping up.
argument-hint: "[days | all]   e.g. 7  (default), or  all  for full history"
allowed-tools: Bash, Read, Write, Glob, Grep, Task
model: opus
---

You are the ORCHESTRATOR of a deep-review pipeline. Do the cross-referencing yourself; delegate the reading to subagents. Subagents cannot spawn subagents, so every dispatch happens from here.

## Step 1 - Run the deterministic engine (code does the counting)
Interpret `$ARGUMENTS`: if it is `all`, pass `--all`; if it is a number N, pass `--days N`; if empty, default to `--days 7`.

Run from the repo root:
```
python3 .claude/analysis/analyze_sessions.py --project-path . [--all | --days N]
```
Capture the `RUN_DIR=...` line from stdout — that path is the input for every analyst. Read `RUN_DIR/schema_report.json` and `RUN_DIR/metrics.json` and give the user a one-line headline (sessions, turns, tool calls, compactions, retry loops, error clusters, est. cost) before continuing. If the engine errored on locating the project dir, surface the listed available dirs and ask which to use.

## Step 2 - Fan out analysts IN PARALLEL (dispatch in a single batch)
Pass each subagent the absolute `RUN_DIR`. Launch these concurrently:
- **cc-friction-analyst** — RUN_DIR
- **cc-prompting-analyst** — RUN_DIR
- **cc-error-analyst** — RUN_DIR
- **cc-continuity-analyst** — RUN_DIR
- **cc-code-health-analyst** — RUN_DIR

For **cc-project-progress-analyst**: check `RUN_DIR/slices/decisions/`. If there are 3 or fewer week files, dispatch ONE instance over the whole folder. If there are more than 3 (a long `--all` run), MAP-REDUCE: dispatch one instance per week file in parallel (each told to use the 250-word single-week format), then you merge their changelogs/decisions/open-threads in Step 3. Do the same per-week split for **cc-code-health-analyst** only if churn.json is very large.

## Step 3 - Synthesize (this is your job, not a subagent's)
Cross-reference the reports against each other and against metrics.json. The value is in the connections: e.g. a retry loop (friction) + its error cluster (error) + the feature it blocked (project) = ONE rooted insight, not three. Resolve any per-week map-reduce outputs into single sections. Prioritize ruthlessly: lead with the few changes that would most improve next week.

## Step 4 - Write the report
Write to `docs/reviews/<YYYY-MM-DD>.md` (create the folder if needed) with this structure:
```
# Deep Review - <window> - <date>

## Headline metrics
<the exact numbers from metrics.json: time split, tokens, est cost, tool mix, compactions>

## Top 3 changes to use Claude Code better
<ranked, specific, each tied to real evidence and a concrete action>

## How the project is shaping up
<changelog + decisions + open threads, synthesized from the project analyst>

## Skill & code-health signals
<prompting, continuity, instability findings, condensed>

## CLAUDE.md / command additions to make now
<paste-ready rules and slash-command ideas the analysts proposed>
```

## Step 5 - Trend note
The engine already appended this run to `.analysis/trends.sqlite`. Query it with Python (always available; avoids depending on a sqlite3 CLI):
```
python3 -c "import sqlite3;[print(r) for r in sqlite3.connect('.analysis/trends.sqlite').execute('select run_id,sessions,turns,retry_loops,error_clusters,cost from runs order by ts desc limit 6')]"
```
If 2+ prior runs exist, add a short **## Trend vs last runs** section: are retry loops, error clusters, compactions, and cost-per-session trending down? That trend is the real measure of whether the user's Claude Code skill is improving — call it out honestly.

Finally, tell the user the report path and the single most important takeaway in one sentence.
