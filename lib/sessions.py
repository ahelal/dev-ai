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


def cmd_show(session_id: str, args: argparse.Namespace) -> None:
    matches = [p for p in SESSION_DIR.glob("*/") if p.name.startswith(session_id)]

    if not matches:
        print(f"No session found matching '{session_id}'", file=sys.stderr)
        sys.exit(1)

    if len(matches) > 1:
        print(f"Ambiguous prefix '{session_id}'. Matches:", file=sys.stderr)
        for m in sorted(matches):
            meta = read_session_meta(m)
            if meta:
                print(f"  {m.name}  {fmt_date(meta['start_time'])}  {project_name(meta['cwd'])}",
                      file=sys.stderr)
        sys.exit(1)

    session_path = matches[0]
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

EXAMPLES
  copilot-session
  copilot-session list --model claude --since 2026-05-01
  copilot-session stats --project dev-ai
  copilot-session messages --search "add unit tests" --limit 10
  copilot-session show abc123
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
