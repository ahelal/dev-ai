#!/usr/bin/env python3
"""
copilot-session — query local Copilot CLI session history.

Reads from: ~/.copilot/session-state/*/events.jsonl
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SESSION_DIR = Path.home() / ".copilot" / "session-state"

# ---------------------------------------------------------------------------
# Efficient JSONL reading helpers
# ---------------------------------------------------------------------------

def _read_first_line(path: Path) -> dict | None:
    try:
        with open(path) as f:
            line = f.readline()
        return json.loads(line) if line else None
    except Exception:
        return None


def _find_last_shutdown(path: Path) -> dict | None:
    """Read the tail of a file (16 KB) to locate the last session.shutdown event."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            tail_size = min(size, 16 * 1024)
            f.seek(size - tail_size)
            raw = f.read(tail_size).decode("utf-8", errors="replace")
        for line in reversed(raw.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
                if ev.get("type") == "session.shutdown":
                    return ev
            except Exception:
                pass
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Session metadata
# ---------------------------------------------------------------------------

def read_session_meta(session_path: Path) -> dict | None:
    events_file = session_path / "events.jsonl"
    if not events_file.exists():
        return None

    start_event = _read_first_line(events_file)
    if not start_event or start_event.get("type") not in ("session.start", "session.resume"):
        return None

    shutdown_event = _find_last_shutdown(events_file)

    start_data = start_event.get("data", {})
    ctx = start_data.get("context", {})

    meta: dict = {
        "session_id": session_path.name,
        "start_time": start_data.get("startTime") or start_event.get("timestamp", ""),
        "model": start_data.get("selectedModel", "?"),
        "cwd": ctx.get("cwd", ""),
        "branch": ctx.get("branch", ""),
        "git_root": ctx.get("gitRoot", ""),
        "head_commit": ctx.get("headCommit", ""),
        "status": "complete" if shutdown_event else "running",
    }

    if shutdown_event:
        sd = shutdown_event.get("data", {})
        meta["shutdown_type"] = sd.get("shutdownType", "")
        meta["duration_ms"] = sd.get("totalApiDurationMs", 0)
        meta["total_premium_requests"] = sd.get("totalPremiumRequests", 0)
        meta["current_model"] = sd.get("currentModel", meta["model"])
        meta["code_changes"] = sd.get("codeChanges", {})

        model_metrics = sd.get("modelMetrics", {})
        total_in = total_out = 0
        for mm in model_metrics.values():
            usage = mm.get("usage", {})
            total_in += usage.get("inputTokens", 0)
            total_out += usage.get("outputTokens", 0)
        meta["input_tokens"] = total_in
        meta["output_tokens"] = total_out

    # vscode.metadata.json contains firstUserMessage (fast access)
    vm_file = session_path / "vscode.metadata.json"
    if vm_file.exists():
        try:
            vm = json.loads(vm_file.read_text())
            raw = vm.get("firstUserMessage", "") or ""
            meta["first_message"] = raw[:120].replace("\n", " ")
        except Exception:
            meta["first_message"] = ""
    else:
        meta["first_message"] = ""

    return meta


# ---------------------------------------------------------------------------
# Session loading with filters
# ---------------------------------------------------------------------------

def _parse_date(s: str) -> datetime:
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def load_sessions(args: argparse.Namespace) -> list[dict]:
    since_dt = _parse_date(args.since) if getattr(args, "since", None) else None
    before_dt = _parse_date(args.before) if getattr(args, "before", None) else None

    sessions = []
    for sd in sorted(SESSION_DIR.glob("*/")):
        if not sd.is_dir():
            continue
        meta = read_session_meta(sd)
        if not meta:
            continue

        # Cheap filters — evaluated before any further I/O
        if since_dt or before_dt:
            try:
                ts = datetime.fromisoformat(meta["start_time"].replace("Z", "+00:00"))
                if since_dt and ts < since_dt:
                    continue
                if before_dt and ts >= before_dt:
                    continue
            except Exception:
                pass

        if getattr(args, "model", None) and args.model.lower() not in meta["model"].lower():
            continue
        if getattr(args, "project", None) and args.project.lower() not in meta["cwd"].lower():
            continue
        if getattr(args, "branch", None) and args.branch.lower() not in meta["branch"].lower():
            continue

        status_filter = getattr(args, "status", "all")
        if status_filter and status_filter != "all" and meta["status"] != status_filter:
            continue

        sessions.append(meta)

    # Sort newest first
    sessions.sort(key=lambda s: s["start_time"], reverse=True)

    # Expensive event-scan filters (--tool, --search) applied after sorting
    tool_filter = getattr(args, "tool", None)
    search_filter = getattr(args, "search", None)
    if tool_filter or search_filter:
        sessions = [s for s in sessions if _scan_events(s["session_id"], tool_filter, search_filter)]

    limit = getattr(args, "limit", 50)
    if limit:
        sessions = sessions[:limit]

    return sessions


def _scan_events(session_id: str, tool_filter: str | None, search_filter: str | None) -> bool:
    """Return True if the session matches both tool and search filters."""
    events_file = SESSION_DIR / session_id / "events.jsonl"
    tool_found = not tool_filter
    search_found = not search_filter

    try:
        with open(events_file) as f:
            for line in f:
                if tool_found and search_found:
                    break
                try:
                    ev = json.loads(line)
                    ev_type = ev.get("type", "")
                    if not tool_found and ev_type == "tool.execution_start":
                        if tool_filter.lower() in ev.get("data", {}).get("toolName", "").lower():
                            tool_found = True
                    if not search_found and ev_type == "user.message":
                        content = ev.get("data", {}).get("content", "")
                        if search_filter.lower() in content.lower():
                            search_found = True
                except Exception:
                    pass
    except Exception:
        return False

    return tool_found and search_found


# ---------------------------------------------------------------------------
# Event readers (for messages / show)
# ---------------------------------------------------------------------------

def get_user_messages(session_id: str) -> list[dict]:
    events_file = SESSION_DIR / session_id / "events.jsonl"
    msgs = []
    try:
        with open(events_file) as f:
            for line in f:
                try:
                    ev = json.loads(line)
                    if ev.get("type") == "user.message":
                        msgs.append({
                            "timestamp": ev.get("timestamp", ""),
                            "content": ev.get("data", {}).get("content", ""),
                        })
                except Exception:
                    pass
    except Exception:
        pass
    return msgs


def get_all_events(session_id: str) -> list[dict]:
    events_file = SESSION_DIR / session_id / "events.jsonl"
    events = []
    try:
        with open(events_file) as f:
            for line in f:
                try:
                    events.append(json.loads(line))
                except Exception:
                    pass
    except Exception:
        pass
    return events


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def fmt_duration(ms: int) -> str:
    if not ms:
        return "-"
    s = ms // 1000
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    return f"{m}m{s:02d}s"


def fmt_date(iso: str) -> str:
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M")
    except Exception:
        return iso[:16] if iso else "?"


def project_name(cwd: str) -> str:
    if not cwd:
        return "?"
    return cwd.rstrip("/").split("/")[-1] or cwd


# ---------------------------------------------------------------------------
# Analyze helpers — token / duration math and table rendering
# ---------------------------------------------------------------------------

def _iso_dt(s: str) -> datetime | None:
    try:
        return datetime.fromisoformat((s or "").replace("Z", "+00:00"))
    except Exception:
        return None


def _ms_between(a: str, b: str) -> int:
    da, db = _iso_dt(a), _iso_dt(b)
    if not da or not db:
        return 0
    return int((db - da).total_seconds() * 1000)


def est_tokens_from_chars(n) -> int:
    """Rough token estimate (~4 chars/token) for text that has no exact count."""
    n = int(n or 0)
    return round(n / 4) if n > 0 else 0


def est_tokens(text: str) -> int:
    return est_tokens_from_chars(len(text or ""))


def fmt_ms(ms) -> str:
    if ms is None:
        return "-"
    ms = int(ms)
    if ms <= 0:
        return "-"
    if ms < 1000:
        return f"{ms}ms"
    s = ms / 1000
    if s < 60:
        return f"{s:.1f}s"
    m, sec = divmod(int(round(s)), 60)
    return f"{m}m{sec:02d}s"


def fmt_int(n) -> str:
    try:
        return f"{int(n):,}"
    except Exception:
        return str(n)


def fmt_aiu(aiu) -> str:
    """Format AI credits (AIU). Shows 2 decimals, thousands-separated."""
    try:
        aiu = float(aiu or 0)
    except Exception:
        return str(aiu)
    if aiu <= 0:
        return "-"
    return f"{aiu:,.2f}"


def fmt_clock(iso: str) -> str:
    dt = _iso_dt(iso)
    if dt:
        return dt.strftime("%H:%M:%S")
    return iso[11:19] if len(iso) >= 19 else "?"


def _trunc(s: str, n: int) -> str:
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _summarize_args(name: str, args) -> str:
    """Compact one-line summary of a tool call's most informative argument."""
    if not isinstance(args, dict) or not args:
        return ""
    for k in ("path", "command", "pattern", "query", "file_text", "filePath",
              "url", "old_str", "prompt", "description"):
        v = args.get(k)
        if isinstance(v, str) and v:
            return f"{k}={_trunc(v, 55)}"
    k = next(iter(args))
    return f"{k}={_trunc(str(args[k]), 55)}"


def render_table(headers: list[str], rows: list[list], aligns: list[str] | None = None) -> str:
    cols = len(headers)
    aligns = aligns or ["l"] * cols
    srows = [[str(c) for c in r] for r in rows]
    widths = [len(str(h)) for h in headers]
    for r in srows:
        for i in range(cols):
            widths[i] = max(widths[i], len(r[i]))

    def line(cells: list[str]) -> str:
        out = []
        for i, c in enumerate(cells):
            out.append(c.rjust(widths[i]) if aligns[i] == "r" else c.ljust(widths[i]))
        return "  ".join(out).rstrip()

    sep = "  ".join("─" * w for w in widths)
    return "\n".join([line([str(h) for h in headers]), sep] + [line(r) for r in srows])


def _resolve_session(prefix: str) -> Path:
    """Resolve a session ID or unique prefix to a session directory, or exit."""
    matches = [p for p in SESSION_DIR.glob("*/") if p.name.startswith(prefix)]
    if not matches:
        print(f"No session found matching '{prefix}'", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"Ambiguous prefix '{prefix}'. Matches:", file=sys.stderr)
        for m in sorted(matches):
            meta = read_session_meta(m)
            if meta:
                print(f"  {m.name}  {fmt_date(meta['start_time'])}  {project_name(meta['cwd'])}",
                      file=sys.stderr)
        sys.exit(1)
    return matches[0]


# ---------------------------------------------------------------------------
# Analyze — single-pass deconstruction of a session's events
# ---------------------------------------------------------------------------

def analyze_session(session_path: Path) -> dict:
    events = get_all_events(session_path.name)
    if not events:
        return {}

    start_ts = events[0].get("timestamp", "")
    end_ts = events[-1].get("timestamp", "")
    start_data = events[0].get("data", {})
    ctx = start_data.get("context", {})

    models: list[str] = []
    model_changes: list[dict] = []
    system_msgs: list[dict] = []
    interactions: list[dict] = []
    timeline: list[dict] = []
    tools: dict[str, dict] = {}
    subagents: list[dict] = []
    compactions: list[dict] = []

    counts = {"prompts": 0, "assistant_messages": 0, "tool_calls": 0, "turns": 0,
              "subagents": 0, "compactions": 0, "aborts": 0, "notifications": 0,
              "system_messages": 0}

    open_tools: dict[str, dict] = {}
    open_subagents: dict[str, dict] = {}
    shutdown: dict | None = None
    cur: dict | None = None
    prev_ts = start_ts

    def add_tl(section, name, tokens, est, duration_ms, ts, detail):
        timeline.append({
            "clock": fmt_clock(ts),
            "offset_ms": _ms_between(start_ts, ts),
            "section": section,
            "name": name,
            "tokens": tokens,
            "est": est,
            "duration_ms": duration_ms,
            "detail": detail,
        })

    base_model = start_data.get("selectedModel")
    if base_model:
        models.append(base_model)

    for ev in events:
        t = ev.get("type", "")
        d = ev.get("data", {}) or {}
        ts = ev.get("timestamp", "")

        if t == "session.model_change":
            nm = d.get("newModel", "")
            if nm and nm not in models:
                models.append(nm)
            model_changes.append({"time": ts, "model": nm,
                                  "reasoning_effort": d.get("reasoningEffort")})
            add_tl("MODEL", nm, 0, False, None, ts,
                   f"reasoning={d.get('reasoningEffort', '?')}")

        elif t == "system.message":
            counts["system_messages"] += 1
            content = d.get("content", "") or ""
            system_msgs.append({"chars": len(content), "est_tokens": est_tokens(content),
                                "preview": _trunc(content, 200)})
            add_tl("SYSTEM", "system prompt", est_tokens(content), True, None, ts,
                   f"{len(content):,} chars")

        elif t == "user.message":
            counts["prompts"] += 1
            content = d.get("content", "") or ""
            sent = d.get("transformedContent") or content
            cur = {
                "idx": counts["prompts"], "time": ts,
                "preview": _trunc(content, 70),
                "est_in_tokens": est_tokens(sent),
                "out_tokens": 0, "turns": 0, "tools": 0, "ok": 0, "fail": 0,
                "end_ts": ts,
            }
            interactions.append(cur)
            add_tl("USER", f"#{counts['prompts']}", est_tokens(sent), True, None, ts,
                   _trunc(content, 80))

        elif t == "assistant.turn_start":
            counts["turns"] += 1
            if cur:
                cur["turns"] += 1
                cur["end_ts"] = ts

        elif t == "assistant.turn_end":
            if cur:
                cur["end_ts"] = ts

        elif t == "assistant.message":
            counts["assistant_messages"] += 1
            out = int(d.get("outputTokens", 0) or 0)
            if cur:
                cur["out_tokens"] += out
                cur["end_ts"] = ts
            content = d.get("content", "") or ""
            reqs = d.get("toolRequests") or []
            detail = _trunc(content, 80)
            if reqs:
                names = ", ".join(r.get("name", "?") for r in reqs)
                detail = (detail + f"  → req: {names}").strip()
            add_tl("ASSISTANT", d.get("model", ""), out, False,
                   _ms_between(prev_ts, ts), ts, _trunc(detail, 90))

        elif t == "tool.execution_start":
            open_tools[d.get("toolCallId")] = {
                "name": d.get("toolName", "?"), "ts": ts,
                "args": d.get("arguments", {}),
            }

        elif t == "tool.execution_complete":
            counts["tool_calls"] += 1
            st = open_tools.pop(d.get("toolCallId"), None)
            name = (st or {}).get("name") or "?"
            metrics = d.get("toolTelemetry", {}).get("metrics", {}) or {}
            dur = metrics.get("durationMs")
            if dur is None and st:
                dur = _ms_between(st["ts"], ts)
            res_chars = metrics.get("resultForLlmLength")
            if res_chars is None:
                res_chars = metrics.get("resultLength")
            if res_chars is None:
                res_chars = len((d.get("result", {}) or {}).get("content", "") or "")
            res_tokens = est_tokens_from_chars(res_chars)
            success = bool(d.get("success"))
            tinfo = tools.setdefault(name, {"calls": 0, "ok": 0, "fail": 0,
                                            "result_tokens": 0, "total_ms": 0})
            tinfo["calls"] += 1
            tinfo["ok" if success else "fail"] += 1
            tinfo["result_tokens"] += res_tokens
            tinfo["total_ms"] += int(dur or 0)
            if cur:
                cur["tools"] += 1
                cur["ok" if success else "fail"] += 1
                cur["end_ts"] = ts
            flag = "" if success else "  ✗FAIL"
            add_tl("TOOL", name, res_tokens, True, int(dur or 0), ts,
                   _trunc(_summarize_args(name, (st or {}).get("args", {})) + flag, 90))

        elif t == "subagent.started":
            open_subagents[ev.get("agentId") or d.get("toolCallId")] = {
                "name": d.get("agentName", "?"), "model": d.get("model", ""), "ts": ts}

        elif t == "subagent.completed":
            counts["subagents"] += 1
            st = open_subagents.pop(ev.get("agentId") or d.get("toolCallId"), None)
            dur = d.get("durationMs")
            if dur is None and st:
                dur = _ms_between(st["ts"], ts)
            tok = int(d.get("totalTokens", 0) or 0)
            sa = {"name": d.get("agentName", "?"), "model": d.get("model", ""),
                  "tool_calls": d.get("totalToolCalls", 0), "tokens": tok,
                  "duration_ms": int(dur or 0)}
            subagents.append(sa)
            add_tl("SUBAGENT", sa["name"], tok, False, sa["duration_ms"], ts,
                   f"{sa['tool_calls']} tool calls")

        elif t == "session.compaction_complete":
            counts["compactions"] += 1
            comp = {"time": ts, "pre_tokens": d.get("preCompactionTokens", 0),
                    "pre_messages": d.get("preCompactionMessagesLength", 0)}
            compactions.append(comp)
            add_tl("COMPACT", "", comp["pre_tokens"], False, None, ts,
                   f"{fmt_int(comp['pre_tokens'])} tok / {comp['pre_messages']} msgs compacted")

        elif t == "abort":
            counts["aborts"] += 1
            add_tl("ABORT", "", 0, False, None, ts, d.get("reason", ""))

        elif t == "system.notification":
            counts["notifications"] += 1

        elif t == "session.shutdown":
            shutdown = d

        if t != "tool.execution_start":
            prev_ts = ts

    for i, it in enumerate(interactions):
        nxt = interactions[i + 1]["time"] if i + 1 < len(interactions) else end_ts
        it["duration_ms"] = _ms_between(it["time"], nxt)

    tools_list = []
    for name, ti in sorted(tools.items(), key=lambda kv: -kv[1]["calls"]):
        tools_list.append({
            "name": name, "calls": ti["calls"], "ok": ti["ok"], "fail": ti["fail"],
            "result_tokens_est": ti["result_tokens"], "total_ms": ti["total_ms"],
            "avg_ms": int(ti["total_ms"] / ti["calls"]) if ti["calls"] else 0,
        })

    totals: dict = {}
    model_metrics: dict = {}
    code_changes: dict = {}
    if shutdown:
        totals = {
            "premium_requests": shutdown.get("totalPremiumRequests", 0),
            "api_duration_ms": shutdown.get("totalApiDurationMs", 0),
            "system_tokens": shutdown.get("systemTokens", 0),
            "conversation_tokens": shutdown.get("conversationTokens", 0),
            "tool_definitions_tokens": shutdown.get("toolDefinitionsTokens", 0),
            "current_tokens": shutdown.get("currentTokens", 0),
            "nano_aiu": shutdown.get("totalNanoAiu", 0),
            "ai_credits": (shutdown.get("totalNanoAiu", 0) or 0) / 1e9,
        }
        ti_ = to_ = cr_ = cw_ = rt_ = 0
        for mname, mm in (shutdown.get("modelMetrics", {}) or {}).items():
            u = mm.get("usage", {}) or {}
            nano = mm.get("totalNanoAiu", 0) or 0
            model_metrics[mname] = {
                "requests": mm.get("requests", {}).get("count", 0),
                "premium_requests": mm.get("requests", {}).get("cost", 0),
                "input": u.get("inputTokens", 0), "output": u.get("outputTokens", 0),
                "cache_read": u.get("cacheReadTokens", 0),
                "cache_write": u.get("cacheWriteTokens", 0),
                "reasoning": u.get("reasoningTokens", 0),
                "nano_aiu": nano, "ai_credits": nano / 1e9,
            }
            ti_ += u.get("inputTokens", 0)
            to_ += u.get("outputTokens", 0)
            cr_ += u.get("cacheReadTokens", 0)
            cw_ += u.get("cacheWriteTokens", 0)
            rt_ += u.get("reasoningTokens", 0)
        totals.update({"input_tokens": ti_, "output_tokens": to_,
                       "cache_read_tokens": cr_, "cache_write_tokens": cw_,
                       "reasoning_tokens": rt_})
        code_changes = shutdown.get("codeChanges", {}) or {}

    system_prompt = max(system_msgs, key=lambda s: s["chars"]) if system_msgs else {}

    # Subtotals rolled up from the per-section data (exact where the events
    # carry exact counts, estimated otherwise).
    summary = {
        "prompts": counts["prompts"],
        "assistant_messages": counts["assistant_messages"],
        "turns": counts["turns"],
        "subagents": counts["subagents"],
        "compactions": counts["compactions"],
        "aborts": counts["aborts"],
        "tool_calls": counts["tool_calls"],
        "tool_ok": sum(t["ok"] for t in tools_list),
        "tool_fail": sum(t["fail"] for t in tools_list),
        "output_tokens": sum(it["out_tokens"] for it in interactions),
        "user_prompt_tokens_est": sum(it["est_in_tokens"] for it in interactions),
        "tool_result_tokens_est": sum(t["result_tokens_est"] for t in tools_list),
        "system_prompt_tokens_est": system_prompt.get("est_tokens", 0),
        "subagent_tokens": sum(s["tokens"] for s in subagents),
        "tool_time_ms": sum(t["total_ms"] for t in tools_list),
        "subagent_time_ms": sum(s["duration_ms"] for s in subagents),
        "interaction_time_ms": sum(it["duration_ms"] for it in interactions),
    }
    if totals:
        billed = (totals.get("input_tokens", 0) + totals.get("output_tokens", 0)
                  + totals.get("cache_read_tokens", 0) + totals.get("cache_write_tokens", 0))
        summary["total_billed_tokens"] = billed

    return {
        "session_id": session_path.name,
        "start_time": start_ts, "end_time": end_ts,
        "wall_ms": _ms_between(start_ts, end_ts),
        "status": "complete" if shutdown else "running",
        "models": models, "model_changes": model_changes,
        "cwd": ctx.get("cwd", ""), "branch": ctx.get("branch", ""),
        "head_commit": ctx.get("headCommit", ""), "repository": ctx.get("repository", ""),
        "copilot_version": start_data.get("copilotVersion", ""),
        "counts": counts, "totals": totals, "model_metrics": model_metrics,
        "code_changes": code_changes,
        "system_prompt": system_prompt,
        "interactions": interactions, "timeline": timeline,
        "tools": tools_list, "subagents": subagents, "compactions": compactions,
        "summary": summary,
    }


def _render_analysis(a: dict) -> str:
    out: list[str] = []
    P = out.append

    # --- Overview ---------------------------------------------------------
    P(f"Session:   {a['session_id']}")
    P(f"Date:      {fmt_date(a['start_time'])}  →  {fmt_clock(a['end_time'])}  ({a['status']})")
    P(f"Project:   {a['cwd'] or '?'}  [{a['branch'] or '?'}]")
    if a.get("repository"):
        P(f"Repo:      {a['repository']}  @ {(a['head_commit'] or '')[:10]}")
    P(f"Model:     {', '.join(a['models']) or '?'}")
    if a.get("copilot_version"):
        P(f"Copilot:   v{a['copilot_version']}")
    t = a.get("totals", {})
    P(f"Wall time: {fmt_ms(a['wall_ms'])}"
      + (f"   ·   API time: {fmt_ms(t['api_duration_ms'])}" if t.get("api_duration_ms") else "")
      + (f"   ·   Premium reqs: {t['premium_requests']}" if t.get("premium_requests") else ""))
    if t.get("ai_credits"):
        P(f"AI credits: {fmt_aiu(t['ai_credits'])} AIU"
          + (f"   ·   {fmt_aiu(t['ai_credits'] / t['premium_requests'])} AIU/premium req"
             if t.get("premium_requests") else ""))
    c = a["counts"]
    P(f"Activity:  {c['prompts']} prompts · {c['assistant_messages']} replies · "
      f"{c['tool_calls']} tool calls · {c['turns']} turns · {c['subagents']} subagents · "
      f"{c['compactions']} compactions"
      + (f" · {c['aborts']} aborts" if c['aborts'] else ""))
    cc = a.get("code_changes", {})
    if cc:
        fm = cc.get("filesModified", [])
        P(f"Code:      +{cc.get('linesAdded', 0)} / -{cc.get('linesRemoved', 0)} lines "
          f"({len(fm)} file{'s' if len(fm) != 1 else ''})")

    # --- Token breakdown --------------------------------------------------
    P("")
    if t:
        P("TOKEN BREAKDOWN  (exact, from session.shutdown)")
        rows = [
            ["Input (new)", fmt_int(t.get("input_tokens", 0))],
            ["Output", fmt_int(t.get("output_tokens", 0))],
            ["Reasoning", fmt_int(t.get("reasoning_tokens", 0))],
            ["Cache read", fmt_int(t.get("cache_read_tokens", 0))],
            ["Cache write", fmt_int(t.get("cache_write_tokens", 0))],
            ["── context window now ──", ""],
            ["System prompt", fmt_int(t.get("system_tokens", 0))],
            ["Tool definitions", fmt_int(t.get("tool_definitions_tokens", 0))],
            ["Conversation", fmt_int(t.get("conversation_tokens", 0))],
            ["Total context", fmt_int(t.get("current_tokens", 0))],
        ]
        P(render_table(["COMPONENT", "TOKENS"], rows, ["l", "r"]))
    else:
        P("TOKEN BREAKDOWN: session still running — exact totals appear after shutdown.")
        sp = a.get("system_prompt", {})
        if sp:
            P(f"  System prompt ~{fmt_int(sp.get('est_tokens', 0))} tokens "
              f"({fmt_int(sp.get('chars', 0))} chars, estimated)")

    # --- Per-model --------------------------------------------------------
    mm = a.get("model_metrics", {})
    if len(mm) > 1:
        P("")
        P("PER-MODEL METRICS")
        rows = [[m, fmt_int(v["requests"]), fmt_int(v["input"]), fmt_int(v["output"]),
                 fmt_int(v["cache_read"]), fmt_int(v["reasoning"]), fmt_aiu(v.get("ai_credits"))]
                for m, v in mm.items()]
        P(render_table(["MODEL", "REQS", "INPUT", "OUTPUT", "CACHE-R", "REASON", "AI CREDITS"],
                       rows, ["l", "r", "r", "r", "r", "r", "r"]))

    # --- Prompt-by-prompt -------------------------------------------------
    P("")
    P("PROMPT-BY-PROMPT  (each user prompt and the work it triggered)")
    rows = [[f"#{it['idx']}", fmt_clock(it["time"]), f"~{fmt_int(it['est_in_tokens'])}",
             it["turns"], it["tools"], f"{it['ok']}/{it['fail']}",
             fmt_int(it["out_tokens"]), fmt_ms(it["duration_ms"]),
             _trunc(it["preview"], 50)] for it in a["interactions"]]
    sm = a["summary"]
    if len(a["interactions"]) > 1:
        rows.append(["TOTAL", "", f"~{fmt_int(sm['user_prompt_tokens_est'])}",
                     sm["turns"], sm["tool_calls"], f"{sm['tool_ok']}/{sm['tool_fail']}",
                     fmt_int(sm["output_tokens"]), fmt_ms(sm["interaction_time_ms"]), ""])
    P(render_table(["#", "TIME", "IN~", "TURNS", "TOOLS", "OK/FAIL", "OUT TOK", "DURATION", "PROMPT"],
                   rows, ["l", "l", "r", "r", "r", "r", "r", "r", "l"]))

    # --- Tools ------------------------------------------------------------
    if a["tools"]:
        P("")
        P("TOOL USAGE")
        rows = [[ti["name"], ti["calls"], ti["ok"], ti["fail"],
                 f"~{fmt_int(ti['result_tokens_est'])}", fmt_ms(ti["total_ms"]),
                 fmt_ms(ti["avg_ms"])] for ti in a["tools"]]
        if len(a["tools"]) > 1:
            rows.append(["TOTAL", sm["tool_calls"], sm["tool_ok"], sm["tool_fail"],
                         f"~{fmt_int(sm['tool_result_tokens_est'])}",
                         fmt_ms(sm["tool_time_ms"]), ""])
        P(render_table(["TOOL", "CALLS", "OK", "FAIL", "RESULT TOK~", "TOTAL", "AVG"],
                       rows, ["l", "r", "r", "r", "r", "r", "r"]))

    # --- Subagents --------------------------------------------------------
    if a["subagents"]:
        P("")
        P("SUBAGENTS")
        rows = [[s["name"], s["model"], s["tool_calls"], fmt_int(s["tokens"]),
                 fmt_ms(s["duration_ms"])] for s in a["subagents"]]
        P(render_table(["AGENT", "MODEL", "TOOL CALLS", "TOKENS", "DURATION"],
                       rows, ["l", "l", "r", "r", "r"]))

    # --- Section-by-section timeline -------------------------------------
    P("")
    P("SECTION-BY-SECTION TIMELINE  (~ = estimated tokens; exact only in TOKEN BREAKDOWN)")
    tl = a["timeline"]
    note = ""
    limit = a.get("_timeline_limit") or 0
    if limit and len(tl) > limit:
        note = f"  … showing first {limit} of {len(tl)} sections (use --full to see all)"
        tl = tl[:limit]
    rows = []
    for s in tl:
        tok = s["tokens"]
        tok_s = (("~" if s["est"] else "") + fmt_int(tok)) if tok else "-"
        off = fmt_ms(s["offset_ms"]) if s["offset_ms"] else "0s"
        rows.append([s["clock"], off, s["section"], _trunc(s["name"], 22), tok_s,
                     fmt_ms(s["duration_ms"]), _trunc(s["detail"], 58)])
    P(render_table(["CLOCK", "+OFFSET", "SECTION", "NAME", "TOKENS", "DUR", "DETAIL"],
                   rows, ["l", "r", "l", "l", "r", "r", "l"]))
    if note:
        P(note)

    # --- Summary: subtotals & totals -------------------------------------
    P("")
    P("SUMMARY  (subtotals & totals)")
    t = a.get("totals", {})
    srows: list[list] = [
        ["── ACTIVITY ──", ""],
        ["Prompts", fmt_int(sm["prompts"])],
        ["Assistant replies", fmt_int(sm["assistant_messages"])],
        ["Turns", fmt_int(sm["turns"])],
        ["Tool calls", f"{fmt_int(sm['tool_calls'])}  ({sm['tool_ok']} ok / {sm['tool_fail']} fail)"],
        ["Subagents", fmt_int(sm["subagents"])],
        ["Compactions", fmt_int(sm["compactions"])],
    ]
    if sm["aborts"]:
        srows.append(["Aborts", fmt_int(sm["aborts"])])

    srows.append(["── TOKENS ──", ""])
    if t:
        srows += [
            ["Input (new)", fmt_int(t.get("input_tokens", 0))],
            ["Output", fmt_int(t.get("output_tokens", 0))],
            ["Reasoning", fmt_int(t.get("reasoning_tokens", 0))],
            ["Cache read", fmt_int(t.get("cache_read_tokens", 0))],
            ["Cache write", fmt_int(t.get("cache_write_tokens", 0))],
            ["TOTAL billed tokens", fmt_int(sm.get("total_billed_tokens", 0))],
        ]
    else:
        srows.append(["Output (exact, so far)", fmt_int(sm["output_tokens"])])
        srows.append(["Input / cache", "pending shutdown"])
    srows += [
        ["~ User prompts", f"~{fmt_int(sm['user_prompt_tokens_est'])}"],
        ["~ Tool results", f"~{fmt_int(sm['tool_result_tokens_est'])}"],
        ["~ System prompt", f"~{fmt_int(sm['system_prompt_tokens_est'])}"],
    ]
    if sm["subagent_tokens"]:
        srows.append(["Subagent tokens", fmt_int(sm["subagent_tokens"])])

    srows.append(["── TIME ──", ""])
    srows.append(["Tool time (subtotal)", fmt_ms(sm["tool_time_ms"])])
    if sm["subagent_time_ms"]:
        srows.append(["Subagent time", fmt_ms(sm["subagent_time_ms"])])
    if t.get("api_duration_ms"):
        srows.append(["API time", fmt_ms(t["api_duration_ms"])])
    if t.get("premium_requests"):
        srows.append(["Premium requests", fmt_int(t["premium_requests"])])
    srows.append(["TOTAL wall time", fmt_ms(a["wall_ms"])])

    if t.get("ai_credits"):
        srows.append(["── AI CREDITS (AIU) ──", ""])
        for m, v in mm.items():
            if v.get("ai_credits"):
                srows.append([f"  {m}", fmt_aiu(v["ai_credits"])])
        if t.get("premium_requests"):
            srows.append(["Per premium request",
                          fmt_aiu(t["ai_credits"] / t["premium_requests"])])
        srows.append(["TOTAL AI credits", fmt_aiu(t["ai_credits"])])

    cc = a.get("code_changes", {})
    if cc:
        fm = cc.get("filesModified", [])
        srows.append(["── CODE ──", ""])
        srows.append(["Lines +/-", f"+{cc.get('linesAdded', 0)} / -{cc.get('linesRemoved', 0)}"])
        srows.append(["Files modified", fmt_int(len(fm))])

    P(render_table(["METRIC", "VALUE"], srows, ["l", "r"]))

    return "\n".join(out)


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

def cmd_list(sessions: list[dict], args: argparse.Namespace) -> None:
    if args.json:
        print(json.dumps(sessions, indent=2))
        return

    if not sessions:
        print("No sessions found.")
        return

    col = "{:<8}  {:<20}  {:<28}  {:<16}  {:<13}  {:<9}  {}"
    print(col.format("ID", "DATE", "MODEL", "BRANCH", "PROJECT", "DURATION", "FIRST MESSAGE"))
    print("─" * 120)
    for s in sessions:
        print(col.format(
            s["session_id"][:8],
            fmt_date(s["start_time"]),
            s["model"][:27],
            (s["branch"] or "?")[:15],
            project_name(s["cwd"])[:12],
            fmt_duration(s.get("duration_ms", 0)),
            s.get("first_message", "")[:50],
        ))


def cmd_stats(sessions: list[dict], args: argparse.Namespace) -> None:
    if not sessions:
        print("No sessions found.")
        return

    model_counts: dict[str, int] = {}
    project_counts: dict[str, int] = {}
    date_counts: dict[str, int] = {}
    total_tokens = 0
    total_duration = 0

    for s in sessions:
        model_counts[s["model"]] = model_counts.get(s["model"], 0) + 1
        p = project_name(s["cwd"])
        project_counts[p] = project_counts.get(p, 0) + 1
        d = s["start_time"][:10]
        date_counts[d] = date_counts.get(d, 0) + 1
        total_tokens += s.get("input_tokens", 0) + s.get("output_tokens", 0)
        total_duration += s.get("duration_ms", 0)

    if args.json:
        print(json.dumps({
            "total": len(sessions),
            "by_model": model_counts,
            "by_project": project_counts,
            "by_date": date_counts,
            "total_tokens": total_tokens,
            "total_duration_ms": total_duration,
        }, indent=2))
        return

    def bar(n: int) -> str:
        return "█" * min(n, 40)

    print(f"Sessions:   {len(sessions)}")
    print(f"Tokens:     {total_tokens:,}")
    print(f"API time:   {fmt_duration(total_duration)}")
    print()

    print("By model:")
    for m, c in sorted(model_counts.items(), key=lambda x: -x[1]):
        print(f"  {m:<40}  {c:4d}  {bar(c)}")
    print()

    print("By project (top 15):")
    for p, c in sorted(project_counts.items(), key=lambda x: -x[1])[:15]:
        print(f"  {p:<30}  {c:4d}  {bar(c)}")
    print()

    print("By date (last 30):")
    for d, c in sorted(date_counts.items(), reverse=True)[:30]:
        print(f"  {d}  {c:4d}  {bar(c)}")


def cmd_messages(sessions: list[dict], args: argparse.Namespace) -> None:
    all_msgs = []
    for s in sessions:
        for m in get_user_messages(s["session_id"]):
            all_msgs.append({
                **m,
                "session_id": s["session_id"],
                "project": project_name(s["cwd"]),
                "model": s["model"],
            })

    if args.json:
        print(json.dumps(all_msgs, indent=2))
        return

    for m in all_msgs:
        content = m["content"][:300].replace("\n", " ")
        print(f"[{fmt_date(m['timestamp'])}] [{m['project']}]  {content}")
        print()


def cmd_analyze(session_id: str, args: argparse.Namespace) -> None:
    session_path = _resolve_session(session_id)
    a = analyze_session(session_path)
    if not a:
        print(f"Could not read session {session_path.name}", file=sys.stderr)
        sys.exit(1)

    if getattr(args, "json", False):
        print(json.dumps(a, indent=2))
        return

    a["_timeline_limit"] = 0 if getattr(args, "full", False) else (getattr(args, "limit", 0) or 0)
    print(_render_analysis(a))


def cmd_show(session_id: str, args: argparse.Namespace) -> None:
    session_path = _resolve_session(session_id)
    meta = read_session_meta(session_path)

    if not meta:
        print(f"Could not read session {session_path.name}", file=sys.stderr)
        sys.exit(1)

    events = get_all_events(session_path.name)

    if args.json:
        print(json.dumps({"meta": meta, "events": events}, indent=2))
        return

    cc = meta.get("code_changes", {})
    files_modified = cc.get("filesModified", [])

    print(f"Session:   {session_path.name}")
    print(f"Date:      {fmt_date(meta['start_time'])}")
    print(f"Model:     {meta['model']}")
    print(f"Project:   {meta['cwd']}")
    print(f"Branch:    {meta['branch'] or '?'}")
    print(f"Commit:    {meta['head_commit'] or '?'}")
    print(f"Status:    {meta['status']}")
    print(f"Duration:  {fmt_duration(meta.get('duration_ms', 0))}")
    print(f"Tokens:    in={meta.get('input_tokens', 0):,}  out={meta.get('output_tokens', 0):,}")
    if cc:
        print(f"Code:      +{cc.get('linesAdded', 0)} / -{cc.get('linesRemoved', 0)} lines"
              f"  ({len(files_modified)} file{'s' if len(files_modified) != 1 else ''})")
        for fp in files_modified[:10]:
            print(f"           {fp}")
        if len(files_modified) > 10:
            print(f"           … and {len(files_modified) - 10} more")
    print()
    print("─" * 80)

    for ev in events:
        t = ev.get("type", "")
        ts = fmt_date(ev.get("timestamp", ""))
        if t == "user.message":
            content = ev["data"].get("content", "")[:500]
            print(f"\n[{ts}] USER:\n{content}")
        elif t == "assistant.message":
            content = ev["data"].get("content", "")[:500]
            if content:
                print(f"\n[{ts}] ASSISTANT:\n{content}")
        elif t == "tool.execution_start":
            tn = ev["data"].get("toolName", "")
            print(f"\n[{ts}] TOOL: {tn}")


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _add_filters(p: argparse.ArgumentParser) -> None:
    p.add_argument("--project", "-p", metavar="TEXT", help="Filter by cwd (substring)")
    p.add_argument("--branch", "-b", metavar="TEXT", help="Filter by git branch (substring)")
    p.add_argument("--model", "-m", metavar="TEXT", help="Filter by model name (substring)")
    p.add_argument("--since", metavar="YYYY-MM-DD", help="Sessions on/after this date")
    p.add_argument("--before", metavar="YYYY-MM-DD", help="Sessions before this date")
    p.add_argument("--tool", metavar="NAME", help="Sessions that used a specific tool")
    p.add_argument("--search", "-s", metavar="TEXT", help="Search user message content")
    p.add_argument("--status", choices=["complete", "running", "all"], default="all",
                   help="Filter by session status (default: all)")
    p.add_argument("--limit", "-n", type=int, default=50, metavar="N",
                   help="Max results (default: 50)")
    p.add_argument("--json", "-j", action="store_true", help="Output as JSON")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="copilot-session",
        description="Query local Copilot CLI session history (~/.copilot/session-state/).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
SUBCOMMANDS
  list      Tabular list of sessions (default)
  stats     Aggregate stats by model, project, and date
  messages  Show user messages from matched sessions
  show ID   Full detail + conversation for one session (ID prefix supported)
  analyze ID  Deep per-section breakdown: prompts, tools, tokens & durations

EXAMPLES
  copilot-session
  copilot-session list --model claude --since 2026-05-01
  copilot-session stats --project dev-ai
  copilot-session messages --search "add unit tests" --limit 10
  copilot-session show abc123
  copilot-session analyze abc123
        """,
    )
    _add_filters(parser)

    sub = parser.add_subparsers(dest="command")

    list_p = sub.add_parser("list", help="Tabular list of sessions")
    _add_filters(list_p)

    stats_p = sub.add_parser("stats", help="Aggregate stats by model/project/date")
    _add_filters(stats_p)
    stats_p.add_argument("--no-limit", action="store_true",
                         help="Include all sessions (ignore --limit)")

    msg_p = sub.add_parser("messages", help="Show user messages from matched sessions")
    _add_filters(msg_p)

    show_p = sub.add_parser("show", help="Full detail for one session (ID prefix supported)")
    show_p.add_argument("session_id", help="Session ID or unique prefix")
    show_p.add_argument("--json", "-j", action="store_true", help="Output as JSON")

    analyze_p = sub.add_parser(
        "analyze", aliases=["analyse"],
        help="Deep per-section analysis of one session (tokens & durations)")
    analyze_p.add_argument("session_id", help="Session ID or unique prefix")
    analyze_p.add_argument("--limit", "-n", type=int, default=0, metavar="N",
                           help="Cap the timeline to N sections (0 = all, the default)")
    analyze_p.add_argument("--full", action="store_true",
                           help="Never cap the timeline (overrides --limit)")
    analyze_p.add_argument("--json", "-j", action="store_true", help="Output as JSON")

    return parser


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        args.command = "list"

    if args.command == "show":
        cmd_show(args.session_id, args)
        return

    if args.command in ("analyze", "analyse"):
        cmd_analyze(args.session_id, args)
        return

    if args.command == "stats" and getattr(args, "no_limit", False):
        args.limit = None

    sessions = load_sessions(args)

    if args.command == "list":
        cmd_list(sessions, args)
    elif args.command == "stats":
        cmd_stats(sessions, args)
    elif args.command == "messages":
        cmd_messages(sessions, args)


if __name__ == "__main__":
    main()
