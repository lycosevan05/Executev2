#!/usr/bin/env python3
"""
analyze_sessions.py  -  Stage 0/1/4 of the Claude Code deep-review pipeline.

What it does (all in deterministic code, no LLM):
  Stage 0  Locate the project's session dir, discover the actual JSONL schema,
           stream-parse sessions line-by-line, normalize each turn.
  Stage 1  Compute exact metrics: time, tokens, tool usage, retries, file churn,
           errors (clustered), workflow signals, compaction events.
  Stage 4  Append this run's headline metrics to a longitudinal SQLite store so
           week-over-week trends emerge.

It then writes small, purpose-built SLICES that the six interpretive subagents
read. The subagents never touch raw JSONL - that is the whole point, and it is
why this scales to a multi-GB ~/.claude/projects folder.

Stdlib only. No pip install required.

Usage:
  python3 analyze_sessions.py --project-path . --days 7
  python3 analyze_sessions.py --project-path . --all
  python3 analyze_sessions.py --project-path . --days 7 --tz America/Vancouver
"""

import argparse
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except ImportError:  # py<3.9 fallback
    ZoneInfo = None

# --- Pricing: EDITABLE. Cost is a rough estimate only. Update per-million-token
# rates from the current pricing page before trusting the dollar figures. Token
# COUNTS below are always exact regardless of these numbers. ---
RATES_PER_MTOK = {
    # model_substring : (input, output, cache_write, cache_read)  USD / 1M tokens
    "opus":   (15.0, 75.0, 18.75, 1.50),
    "sonnet": (3.0,  15.0, 3.75,  0.30),
    "haiku":  (0.80, 4.0,  1.0,   0.08),
}
IDLE_GAP_MIN = 15          # gap > this (minutes) between turns counts as idle
RETRY_THRESHOLD = 3        # identical bash command run >= this many times = retry loop
CHURN_REREAD_FLAG = 4      # file read >= this many times = re-read hotspot
SNIPPET = 240              # chars of error text kept per error sample


# ---------------------------------------------------------------------------
# Stage 0 : locate project dir + stream-parse
# ---------------------------------------------------------------------------
def resolve_project_dir(claude_dir: Path, project_path: Path):
    """Find ~/.claude/projects/<encoded>. Prefer matching the real cwd recorded
    inside the sessions; fall back to path-encoding (slashes -> dashes)."""
    projects = claude_dir / "projects"
    if not projects.is_dir():
        sys.exit(f"[fatal] {projects} does not exist. Check --claude-dir.")

    target = str(project_path.resolve())
    # 1) robust match: read one line of each session, compare its cwd field
    for d in sorted(projects.iterdir()):
        if not d.is_dir():
            continue
        for f in d.glob("*.jsonl"):
            try:
                with f.open(encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line:
                            continue
                        obj = json.loads(line)
                        if obj.get("cwd") and Path(obj["cwd"]).resolve() == project_path.resolve():
                            return d
                        break
            except Exception:
                pass
            break
    # 2) fallback: encoded name
    encoded = re.sub(r"[/\\]", "-", target)
    cand = projects / encoded
    if cand.is_dir():
        return cand
    enc2 = "-" + re.sub(r"^[-]+", "", encoded)
    cand2 = projects / enc2
    if cand2.is_dir():
        return cand2
    # 3) give up gracefully: list what's there
    avail = "\n  ".join(p.name for p in projects.iterdir() if p.is_dir())
    sys.exit(f"[fatal] Could not match project {target}.\nAvailable project dirs:\n  {avail}\n"
             f"Pass the right one with --project-dir.")


def parse_ts(raw):
    if not raw:
        return None
    try:
        return datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except Exception:
        return None


def iter_turns(session_file: Path, schema_keys: Counter, schema_types: Counter):
    """Stream a single .jsonl session, yielding normalized turn dicts.
    Defensive: every field via .get(); content may be str or list."""
    with session_file.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue
            for k in raw:                       # schema discovery
                schema_keys[k] += 1
            etype = raw.get("type", "?")
            schema_types[etype] += 1
            msg = raw.get("message") or {}
            usage = msg.get("usage") or {}
            content = msg.get("content")
            blocks = []
            if isinstance(content, list):
                blocks = content
            elif isinstance(content, str):
                blocks = [{"type": "text", "text": content}]

            text_parts, thinking_parts, tool_uses, tool_results = [], [], [], []
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text":
                    text_parts.append(b.get("text", ""))
                elif bt == "thinking":
                    thinking_parts.append(b.get("thinking", ""))
                elif bt == "tool_use":
                    inp = b.get("input") or {}
                    tool_uses.append({
                        "name": b.get("name", "?"),
                        "file_path": inp.get("file_path") or inp.get("notebook_path") or inp.get("path"),
                        "command": inp.get("command"),
                        "input_chars": len(json.dumps(inp, default=str)),
                    })
                elif bt == "tool_result":
                    rc = b.get("content")
                    if isinstance(rc, list):
                        rc = " ".join(x.get("text", "") for x in rc if isinstance(x, dict))
                    tool_results.append({
                        "is_error": bool(b.get("is_error")),
                        "text": (rc or "")[:SNIPPET] if isinstance(rc, str) else "",
                    })

            yield {
                "type": etype,
                "ts": parse_ts(raw.get("timestamp")),
                "model": msg.get("model"),
                "branch": raw.get("gitBranch"),
                "sidechain": bool(raw.get("isSidechain")),
                "usage": usage,
                "text": "\n".join(text_parts).strip(),
                "thinking": "\n".join(thinking_parts).strip(),
                "tool_uses": tool_uses,
                "tool_results": tool_results,
            }


def in_window(turns, after_dt):
    if after_dt is None:
        return True
    return any(t["ts"] and t["ts"] >= after_dt for t in turns)


# ---------------------------------------------------------------------------
# Stage 1 : metrics + slices
# ---------------------------------------------------------------------------
def norm_err(s):
    s = re.sub(r"0x[0-9a-fA-F]+|\b\d+\b", "N", s)
    s = re.sub(r"(/[^\s:]+)+", "PATH", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip()[:120]


def model_rate(model):
    if not model:
        return RATES_PER_MTOK["sonnet"]
    for key, r in RATES_PER_MTOK.items():
        if key in model.lower():
            return r
    return RATES_PER_MTOK["sonnet"]


def iso_week(dt):
    y, w, _ = dt.isocalendar()
    return f"{y}-W{w:02d}"


def analyze(project_dir, after_dt, tz):
    sessions = sorted(project_dir.glob("*.jsonl"))
    schema_keys, schema_types = Counter(), Counter()

    m = {
        "sessions": 0, "turns": 0, "user_turns": 0, "assistant_turns": 0,
        "thinking_turns": 0, "sidechain_turns": 0,
        "tokens": Counter(), "cost_usd": 0.0,
        "tools": Counter(), "bash_categories": Counter(),
        "models": Counter(), "compaction_events": 0,
        "active_minutes": 0.0, "idle_minutes": 0.0,
        "hour_hist": Counter(), "session_durations_min": [],
    }
    retries = Counter()          # (session, cmd) -> count
    file_edits = Counter()
    file_reads = Counter()
    errors = defaultdict(lambda: {"count": 0, "samples": []})
    tool_seq_per_session = {}
    prompts, decisions, boundaries = [], defaultdict(list), []

    for sf in sessions:
        turns = list(iter_turns(sf, schema_keys, schema_types))
        if not in_window(turns, after_dt):
            continue
        m["sessions"] += 1
        sid = sf.stem
        seq = []
        ts_list = [t["ts"] for t in turns if t["ts"]]
        first_ts = min(ts_list) if ts_list else None
        last_ts = max(ts_list) if ts_list else None
        if first_ts and last_ts:
            m["session_durations_min"].append((last_ts - first_ts).total_seconds() / 60)
        boundaries.append({
            "session": sid, "turns": len(turns),
            "start": first_ts.isoformat() if first_ts else None,
            "end": last_ts.isoformat() if last_ts else None,
            "branches": sorted({t["branch"] for t in turns if t["branch"]}),
        })

        prev_ts = None
        for t in turns:
            if after_dt and t["ts"] and t["ts"] < after_dt:
                continue
            m["turns"] += 1
            if t["sidechain"]:
                m["sidechain_turns"] += 1
            if t["type"] == "summary":
                m["compaction_events"] += 1
            if t["model"]:
                m["models"][t["model"]] += 1

            # time
            if t["ts"]:
                local = t["ts"].astimezone(tz) if tz else t["ts"]
                m["hour_hist"][local.hour] += 1
                if prev_ts:
                    gap = (t["ts"] - prev_ts).total_seconds() / 60
                    if gap > IDLE_GAP_MIN:
                        m["idle_minutes"] += gap
                    else:
                        m["active_minutes"] += gap
                prev_ts = t["ts"]

            # tokens / cost (assistant only carries usage)
            u = t["usage"]
            if u:
                ti = u.get("input_tokens", 0); to = u.get("output_tokens", 0)
                cw = u.get("cache_creation_input_tokens", 0); cr = u.get("cache_read_input_tokens", 0)
                m["tokens"]["input"] += ti; m["tokens"]["output"] += to
                m["tokens"]["cache_write"] += cw; m["tokens"]["cache_read"] += cr
                ri, ro, rw, rr = model_rate(t["model"])
                m["cost_usd"] += (ti*ri + to*ro + cw*rw + cr*rr) / 1_000_000

            # role buckets + prompt slice
            if t["type"] == "user" and t["text"]:
                m["user_turns"] += 1
                prompts.append({"ts": t["ts"].isoformat() if t["ts"] else None,
                                "chars": len(t["text"]), "text": t["text"][:1500]})
            if t["type"] == "assistant":
                m["assistant_turns"] += 1
            if t["thinking"]:
                m["thinking_turns"] += 1

            # tools
            for tu in t["tool_uses"]:
                name = tu["name"]; seq.append(name); m["tools"][name] += 1
                if name == "Bash" and tu["command"]:
                    head = tu["command"].strip().split()[0] if tu["command"].strip() else "?"
                    m["bash_categories"][head] += 1
                    retries[(sid, tu["command"].strip()[:200])] += 1
                if name in ("Edit", "MultiEdit", "Write", "NotebookEdit") and tu["file_path"]:
                    file_edits[tu["file_path"]] += 1
                if name == "Read" and tu["file_path"]:
                    file_reads[tu["file_path"]] += 1

            # decision slice (chunked by week): thinking + edit actions
            if t["thinking"] or any(tu["name"] in ("Edit", "MultiEdit", "Write") for tu in t["tool_uses"]):
                wk = iso_week(t["ts"]) if t["ts"] else "undated"
                decisions[wk].append({
                    "ts": t["ts"].isoformat() if t["ts"] else None,
                    "thinking": t["thinking"][:2000],
                    "text": t["text"][:1200],
                    "edits": [tu["file_path"] for tu in t["tool_uses"]
                              if tu["name"] in ("Edit", "MultiEdit", "Write") and tu["file_path"]],
                })

            # errors
            for tr in t["tool_results"]:
                if tr["is_error"] and tr["text"]:
                    sig = norm_err(tr["text"])
                    errors[sig]["count"] += 1
                    if len(errors[sig]["samples"]) < 3:
                        errors[sig]["samples"].append(tr["text"])

        tool_seq_per_session[sid] = seq

    # derive: retry loops, churn hotspots, tool n-grams
    retry_loops = [{"command": cmd, "session": s, "count": c}
                   for (s, cmd), c in retries.items() if c >= RETRY_THRESHOLD]
    retry_loops.sort(key=lambda x: -x["count"])
    churn = {
        "most_edited": file_edits.most_common(25),
        "reread_hotspots": [(f, c) for f, c in file_reads.most_common(40) if c >= CHURN_REREAD_FLAG],
    }
    bigrams = Counter()
    for seq in tool_seq_per_session.values():
        for a, b in zip(seq, seq[1:]):
            bigrams[f"{a}->{b}"] += 1

    error_clusters = sorted(
        [{"signature": k, "count": v["count"], "samples": v["samples"]} for k, v in errors.items()],
        key=lambda x: -x["count"])

    metrics = {
        "totals": {k: m[k] for k in ("sessions", "turns", "user_turns", "assistant_turns",
                                     "thinking_turns", "sidechain_turns", "compaction_events")},
        "tokens": dict(m["tokens"]),
        "cost_usd_estimate": round(m["cost_usd"], 2),
        "time": {
            "active_minutes": round(m["active_minutes"], 1),
            "idle_minutes": round(m["idle_minutes"], 1),
            "median_session_min": round(sorted(m["session_durations_min"])[len(m["session_durations_min"])//2], 1)
                                   if m["session_durations_min"] else 0,
            "hour_histogram": dict(sorted(m["hour_hist"].items())),
        },
        "tools": dict(m["tools"].most_common()),
        "bash_categories": dict(m["bash_categories"].most_common(20)),
        "tool_bigrams": dict(bigrams.most_common(20)),
        "models": dict(m["models"]),
        "retry_loops": retry_loops[:25],
        "churn": churn,
    }
    slices = {
        "prompts": prompts,
        "decisions_by_week": decisions,
        "errors": error_clusters,
        "boundaries": boundaries,
        "tool_sequences": {k: v for k, v in list(tool_seq_per_session.items())[:200]},
    }
    schema = {"keys": dict(schema_keys.most_common()), "entry_types": dict(schema_types)}
    return metrics, slices, schema


# ---------------------------------------------------------------------------
# Stage 4 : longitudinal store
# ---------------------------------------------------------------------------
def append_history(db_path, run_id, metrics):
    con = sqlite3.connect(db_path)
    con.execute("""CREATE TABLE IF NOT EXISTS runs(
        run_id TEXT PRIMARY KEY, ts TEXT, sessions INT, turns INT,
        in_tok INT, out_tok INT, cache_read INT, cost REAL,
        compactions INT, retry_loops INT, error_clusters INT, tool_calls INT)""")
    t = metrics["tokens"]
    con.execute("INSERT OR REPLACE INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (
        run_id, datetime.now(timezone.utc).isoformat(),
        metrics["totals"]["sessions"], metrics["totals"]["turns"],
        t.get("input", 0), t.get("output", 0), t.get("cache_read", 0),
        metrics["cost_usd_estimate"], metrics["totals"]["compaction_events"],
        len(metrics["retry_loops"]), len(slices_error_count(metrics)),
        sum(metrics["tools"].values())))
    con.commit(); con.close()


def slices_error_count(metrics):  # tiny helper to keep schema stable
    return metrics.get("_errors_for_count", [])


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-path", default=".", help="Path to your repo (its cwd, used to find the session dir)")
    ap.add_argument("--project-dir", default=None, help="Override: exact ~/.claude/projects/<dir>")
    ap.add_argument("--claude-dir", default=str(Path.home() / ".claude"))
    ap.add_argument("--days", type=int, default=None)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--tz", default="America/Vancouver")
    ap.add_argument("--out", default=None, help="Output dir (default <project>/.analysis)")
    args = ap.parse_args()

    claude_dir = Path(args.claude_dir).expanduser()
    project_path = Path(args.project_path).expanduser()
    project_dir = Path(args.project_dir).expanduser() if args.project_dir else \
        resolve_project_dir(claude_dir, project_path)

    after_dt = None
    if not args.all:
        days = args.days if args.days is not None else 7
        after_dt = datetime.now(timezone.utc) - timedelta(days=days)

    tz = ZoneInfo(args.tz) if (ZoneInfo and args.tz) else None
    run_id = ("all" if args.all else f"{args.days or 7}d") + "_" + datetime.now().strftime("%Y%m%d_%H%M%S")
    out_root = Path(args.out).expanduser() if args.out else (project_path / ".analysis")
    run_dir = out_root / run_id
    (run_dir / "slices").mkdir(parents=True, exist_ok=True)
    (run_dir / "slices" / "decisions").mkdir(exist_ok=True)

    print(f"[*] project sessions : {project_dir}")
    print(f"[*] window           : {'ALL HISTORY' if args.all else f'last {args.days or 7} days'}")
    metrics, slices, schema = analyze(project_dir, after_dt, tz)
    metrics["_errors_for_count"] = slices["errors"]

    (run_dir / "metrics.json").write_text(json.dumps(metrics, indent=2, default=str))
    (run_dir / "schema_report.json").write_text(json.dumps(schema, indent=2))
    (run_dir / "slices" / "prompts.json").write_text(json.dumps(slices["prompts"], indent=2, default=str))
    (run_dir / "slices" / "errors.json").write_text(json.dumps(slices["errors"], indent=2, default=str))
    (run_dir / "slices" / "boundaries.json").write_text(json.dumps(slices["boundaries"], indent=2, default=str))
    (run_dir / "slices" / "tool_sequences.json").write_text(json.dumps(slices["tool_sequences"], indent=2, default=str))
    (run_dir / "slices" / "churn.json").write_text(json.dumps(metrics["churn"], indent=2, default=str))
    for wk, items in slices["decisions_by_week"].items():
        (run_dir / "slices" / "decisions" / f"{wk}.json").write_text(json.dumps(items, indent=2, default=str))

    append_history(str(out_root / "trends.sqlite"), run_id, metrics)

    # console summary
    t = metrics["totals"]
    print(f"[*] sessions={t['sessions']} turns={t['turns']} "
          f"tool_calls={sum(metrics['tools'].values())} "
          f"compactions={t['compaction_events']} "
          f"retry_loops={len(metrics['retry_loops'])} "
          f"error_clusters={len(slices['errors'])}")
    print(f"[*] est cost (rough): ${metrics['cost_usd_estimate']}  (token counts are exact)")
    print(f"[*] decision weeks   : {sorted(slices['decisions_by_week'].keys())}")
    print(f"[*] artifacts written: {run_dir}")
    print(f"RUN_DIR={run_dir}")   # machine-readable line the slash command greps


if __name__ == "__main__":
    main()
