#!/usr/bin/env python3
"""Monitor estimated Claude Code prompt-cache expiry from local session logs."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable
from zoneinfo import ZoneInfo


SGT = ZoneInfo("Asia/Singapore")
TTL_SECONDS = {"5m": 5 * 60, "1h": 60 * 60}


class CliError(RuntimeError):
    pass


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def iso_sgt(value: datetime | None) -> str | None:
    return value.astimezone(SGT).isoformat(timespec="seconds") if value else None


def positive_int(value: Any) -> int:
    return value if isinstance(value, int) and value > 0 else 0


@dataclass
class CacheRequest:
    request_id: str
    started_after: datetime
    started_before: datetime
    ttls: tuple[str, ...]
    ttl_source: str
    read_tokens: int
    write_tokens: int


@dataclass
class TranscriptInfo:
    session_id: str
    path: Path
    title: str | None
    slug: str | None
    cwd: str | None
    entrypoint: str | None
    version: str | None
    model: str | None
    last_prompt: str | None
    last_activity: datetime | None
    cache_request: CacheRequest | None


@dataclass
class SessionInfo:
    session_id: str
    title: str | None
    cwd: str | None
    entrypoint: str | None
    version: str | None
    model: str | None
    last_prompt: str | None
    running: bool
    transcript_path: str | None
    last_activity: datetime | None
    cache_request: CacheRequest | None


@dataclass
class ParsedRequest:
    request_id: str
    started_after: datetime
    started_before: datetime
    ttls: set[str]
    ttl_source: str
    read_tokens: int = 0
    write_tokens: int = 0
    has_cache_activity: bool = False


def ttl_names(usage: dict[str, Any]) -> set[str]:
    creation = usage.get("cache_creation")
    if not isinstance(creation, dict):
        return set()
    result: set[str] = set()
    if positive_int(creation.get("ephemeral_5m_input_tokens")):
        result.add("5m")
    if positive_int(creation.get("ephemeral_1h_input_tokens")):
        result.add("1h")
    return result


def prompt_preview(value: Any, limit: int = 240) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = " ".join(value.split())
    if not normalized:
        return None
    synthetic_prefixes = (
        "<command-name>",
        "<local-command-caveat>",
        "<local-command-stdout>",
        "<system-reminder>",
        "<task-notification>",
        "This session is being continued from a previous conversation",
    )
    if normalized.startswith(synthetic_prefixes):
        return None
    return normalized if len(normalized) <= limit else normalized[: limit - 1] + "…"


def parse_transcript(path: Path) -> TranscriptInfo:
    session_id = path.stem
    title: str | None = None
    slug: str | None = None
    cwd: str | None = None
    entrypoint: str | None = None
    version: str | None = None
    model: str | None = None
    last_prompt: str | None = None
    last_activity: datetime | None = None
    previous_event_at: datetime | None = None
    known_ttls: set[str] = set()
    current_request: ParsedRequest | None = None
    latest_cached_request: ParsedRequest | None = None

    try:
        source = path.open("r", encoding="utf-8")
    except OSError as exc:
        raise CliError(f"Cannot read transcript {path}: {exc}") from exc

    with source:
        for raw_line in source:
            try:
                item = json.loads(raw_line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if not isinstance(item, dict):
                continue

            item_type = item.get("type")
            timestamp = parse_timestamp(item.get("timestamp"))
            if timestamp and (last_activity is None or timestamp > last_activity):
                last_activity = timestamp

            if item_type == "custom-title" and isinstance(item.get("customTitle"), str):
                title = item["customTitle"].strip() or title

            item_session_id = item.get("sessionId")
            belongs_to_current_session = item_session_id in (None, session_id)
            if item_type == "assistant" and belongs_to_current_session:
                assistant_message = item.get("message")
                assistant_model = assistant_message.get("model") if isinstance(assistant_message, dict) else None
                if isinstance(assistant_model, str) and assistant_model and assistant_model != "<synthetic>":
                    model = assistant_model
            if item_type == "last-prompt" and belongs_to_current_session:
                last_prompt = prompt_preview(item.get("lastPrompt")) or last_prompt
            elif item_type == "user" and belongs_to_current_session and item.get("toolUseResult") is None:
                message = item.get("message")
                if isinstance(message, dict):
                    last_prompt = prompt_preview(message.get("content")) or last_prompt

            for key in ("slug", "cwd", "entrypoint", "version"):
                value = item.get(key)
                if isinstance(value, str) and value:
                    if key == "slug":
                        slug = value
                    elif key == "cwd":
                        cwd = value
                    elif key == "entrypoint":
                        entrypoint = value
                    elif key == "version":
                        version = value

            if item_type == "assistant" and timestamp:
                message = item.get("message")
                usage = message.get("usage") if isinstance(message, dict) else None
                request_id = item.get("requestId")
                if not isinstance(request_id, str) or not request_id:
                    message_id = message.get("id") if isinstance(message, dict) else None
                    request_id = message_id if isinstance(message_id, str) else str(item.get("uuid", timestamp.timestamp()))

                if current_request is None or current_request.request_id != request_id:
                    lower = previous_event_at if previous_event_at and previous_event_at <= timestamp else timestamp
                    current_request = ParsedRequest(
                        request_id=request_id,
                        started_after=lower,
                        started_before=timestamp,
                        ttls=set(),
                        ttl_source="usage",
                    )

                if isinstance(usage, dict):
                    typed_ttls = ttl_names(usage)
                    if typed_ttls:
                        known_ttls = typed_ttls
                        current_request.ttls.update(typed_ttls)

                    read_tokens = positive_int(usage.get("cache_read_input_tokens"))
                    write_tokens = positive_int(usage.get("cache_creation_input_tokens"))
                    if read_tokens or write_tokens:
                        current_request.has_cache_activity = True
                        current_request.read_tokens = max(current_request.read_tokens, read_tokens)
                        current_request.write_tokens = max(current_request.write_tokens, write_tokens)
                        if not current_request.ttls:
                            if known_ttls:
                                current_request.ttls.update(known_ttls)
                                current_request.ttl_source = "inferred-from-earlier-usage"
                            else:
                                current_request.ttls.add("5m")
                                current_request.ttl_source = "anthropic-default"
                        latest_cached_request = current_request

            if timestamp:
                previous_event_at = timestamp

    cache_request: CacheRequest | None = None
    if latest_cached_request:
        cache_request = CacheRequest(
            request_id=latest_cached_request.request_id,
            started_after=latest_cached_request.started_after,
            started_before=latest_cached_request.started_before,
            ttls=tuple(sorted(latest_cached_request.ttls, key=lambda name: TTL_SECONDS[name])),
            ttl_source=latest_cached_request.ttl_source,
            read_tokens=latest_cached_request.read_tokens,
            write_tokens=latest_cached_request.write_tokens,
        )

    return TranscriptInfo(
        session_id=session_id,
        path=path,
        title=title,
        slug=slug,
        cwd=cwd,
        entrypoint=entrypoint,
        version=version,
        model=model,
        last_prompt=last_prompt,
        last_activity=last_activity,
        cache_request=cache_request,
    )


def process_exists(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (OSError, PermissionError):
        return False
    return True


def load_registrations(claude_dir: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for path in (claude_dir / "sessions").glob("*.json"):
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        session_id = item.get("sessionId") if isinstance(item, dict) else None
        if isinstance(session_id, str) and session_id:
            item["_running"] = process_exists(item.get("pid"))
            result[session_id] = item
    return result


def transcript_paths(claude_dir: Path) -> list[Path]:
    projects = claude_dir / "projects"
    if not projects.is_dir():
        return []
    candidates = [path for path in projects.rglob("*.jsonl") if "subagents" not in path.parts]
    candidates.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    deduplicated: dict[str, Path] = {}
    for path in candidates:
        deduplicated.setdefault(path.stem, path)
    return list(deduplicated.values())


class TranscriptCache:
    def __init__(self) -> None:
        self._items: dict[Path, tuple[tuple[int, int], TranscriptInfo]] = {}

    def parse(self, path: Path) -> TranscriptInfo:
        stat = path.stat()
        signature = (stat.st_mtime_ns, stat.st_size)
        cached = self._items.get(path)
        if cached and cached[0] == signature:
            return cached[1]
        result = parse_transcript(path)
        self._items[path] = (signature, result)
        return result


def session_from_transcript(
    transcript: TranscriptInfo,
    registration: dict[str, Any] | None,
) -> SessionInfo:
    registration = registration or {}
    return SessionInfo(
        session_id=transcript.session_id,
        title=transcript.title or transcript.slug,
        cwd=registration.get("cwd") or transcript.cwd,
        entrypoint=registration.get("entrypoint") or transcript.entrypoint,
        version=registration.get("version") or transcript.version,
        model=transcript.model,
        last_prompt=transcript.last_prompt,
        running=bool(registration.get("_running")),
        transcript_path=str(transcript.path),
        last_activity=transcript.last_activity,
        cache_request=transcript.cache_request,
    )


def collect_sessions(
    claude_dir: Path,
    *,
    include_inactive: bool,
    include_cli: bool,
    limit: int,
    selector: str | None,
    cache: TranscriptCache,
) -> list[SessionInfo]:
    registrations = load_registrations(claude_dir)
    paths = transcript_paths(claude_dir)
    path_by_id = {path.stem: path for path in paths}

    if selector:
        matching = [path for path in paths if path.stem.startswith(selector)]
        if not matching:
            raise CliError(f"No session ID starts with {selector!r}")
        if len(matching) > 1:
            matches = ", ".join(path.stem for path in matching[:8])
            raise CliError(f"Session prefix {selector!r} is ambiguous: {matches}")
        info = cache.parse(matching[0])
        return [session_from_transcript(info, registrations.get(info.session_id))]

    if not include_inactive:
        sessions: list[SessionInfo] = []
        for session_id, registration in registrations.items():
            if not registration.get("_running"):
                continue
            if not include_cli and registration.get("entrypoint") != "claude-desktop":
                continue
            path = path_by_id.get(session_id)
            if path:
                sessions.append(session_from_transcript(cache.parse(path), registration))
            else:
                sessions.append(
                    SessionInfo(
                        session_id=session_id,
                        title=None,
                        cwd=registration.get("cwd"),
                        entrypoint=registration.get("entrypoint"),
                        version=registration.get("version"),
                        model=None,
                        last_prompt=None,
                        running=True,
                        transcript_path=None,
                        last_activity=None,
                        cache_request=None,
                    )
                )
        sessions.sort(key=lambda item: item.last_activity or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
        return sessions[:limit]

    sessions = []
    for path in paths:
        info = cache.parse(path)
        registration = registrations.get(info.session_id)
        session = session_from_transcript(info, registration)
        if include_cli or session.entrypoint == "claude-desktop":
            sessions.append(session)
        if len(sessions) >= limit:
            break
    return sessions


def cache_status(session: SessionInfo, now: datetime) -> str:
    request = session.cache_request
    if request is None:
        return "NO_CACHE" if session.transcript_path else "NO_DATA"
    states: list[str] = []
    for ttl in request.ttls:
        seconds = TTL_SECONDS[ttl]
        earliest = request.started_after + timedelta(seconds=seconds)
        latest = request.started_before + timedelta(seconds=seconds)
        if now < earliest:
            states.append("VALID")
        elif now < latest:
            states.append("UNCERTAIN")
        else:
            states.append("EXPIRED")
    if all(state == "VALID" for state in states):
        return "VALID"
    if all(state == "EXPIRED" for state in states):
        return "EXPIRED"
    return "PARTIAL" if len(states) > 1 else "UNCERTAIN"


def format_duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{seconds:02d}s"
    return f"{seconds}s"


def remaining_text(request: CacheRequest | None, now: datetime) -> str:
    if request is None:
        return "-"
    values: list[str] = []
    for ttl in request.ttls:
        seconds = TTL_SECONDS[ttl]
        lower = (request.started_after + timedelta(seconds=seconds) - now).total_seconds()
        upper = (request.started_before + timedelta(seconds=seconds) - now).total_seconds()
        if upper <= 0:
            value = "expired"
        elif lower <= 0:
            value = f"0-{format_duration(upper)}"
        else:
            low_text = format_duration(lower)
            high_text = format_duration(upper)
            value = low_text if low_text == high_text else f"{low_text}-{high_text}"
        values.append(f"{ttl}:{value}" if len(request.ttls) > 1 else value)
    return ",".join(values)


def shorten(value: str | None, width: int) -> str:
    value = value or "-"
    if len(value) <= width:
        return value
    if width <= 1:
        return value[:width]
    return value[: width - 1] + "…"


def render_table(sessions: Iterable[SessionInfo], now: datetime) -> str:
    items = list(sessions)
    terminal_width = shutil.get_terminal_size((120, 24)).columns
    title_width = max(16, min(42, terminal_width - 93))
    rows = []
    for session in items:
        request = session.cache_request
        ttl = "+".join(request.ttls) if request else "-"
        refresh = request.started_after.astimezone(SGT).strftime("%m-%d %H:%M:%S") if request else "-"
        rows.append(
            (
                "yes" if session.running else "no",
                cache_status(session, now),
                ttl,
                remaining_text(request, now),
                refresh,
                shorten(session.model, 24),
                session.session_id[:8],
                shorten(session.title, title_width),
            )
        )

    headers = ("RUN", "CACHE", "TTL", "REMAINING", "REFRESHED SGT", "MODEL", "SESSION", "TITLE")
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def line(values: Iterable[str]) -> str:
        return "  ".join(value.ljust(widths[index]) for index, value in enumerate(values)).rstrip()

    output = [f"Claude prompt cache  {now.astimezone(SGT).strftime('%Y-%m-%d %H:%M:%S SGT')}"]
    if not rows:
        output.append("No matching running Claude Code Desktop sessions.")
        return "\n".join(output)
    output.extend((line(headers), line(tuple("-" * width for width in widths))))
    output.extend(line(row) for row in rows)
    output.append("Remaining time is a local estimate bounded by the preceding event and first assistant event.")
    return "\n".join(output)


def ttl_json(request: CacheRequest | None, now: datetime) -> dict[str, Any] | None:
    if request is None:
        return None
    entries = []
    for ttl in request.ttls:
        seconds = TTL_SECONDS[ttl]
        earliest = request.started_after + timedelta(seconds=seconds)
        latest = request.started_before + timedelta(seconds=seconds)
        entries.append(
            {
                "ttl": ttl,
                "remaining_seconds_lower": max(0, int((earliest - now).total_seconds())),
                "remaining_seconds_upper": max(0, int((latest - now).total_seconds())),
                "expires_at_earliest_sgt": iso_sgt(earliest),
                "expires_at_latest_sgt": iso_sgt(latest),
            }
        )
    return {
        "status": None,
        "request_id": request.request_id,
        "request_started_after_sgt": iso_sgt(request.started_after),
        "request_started_before_sgt": iso_sgt(request.started_before),
        "ttl_source": request.ttl_source,
        "cache_read_input_tokens": request.read_tokens,
        "cache_creation_input_tokens": request.write_tokens,
        "entries": entries,
    }


def render_json(sessions: Iterable[SessionInfo], now: datetime, *, compact: bool = False) -> str:
    payload = []
    for session in sessions:
        cache = ttl_json(session.cache_request, now)
        if cache is not None:
            cache["status"] = cache_status(session, now)
        payload.append(
            {
                "session_id": session.session_id,
                "title": session.title,
                "cwd": session.cwd,
                "entrypoint": session.entrypoint,
                "claude_code_version": session.version,
                "model": session.model,
                "last_prompt": session.last_prompt,
                "running": session.running,
                "transcript_path": session.transcript_path,
                "last_activity_sgt": iso_sgt(session.last_activity),
                "cache": cache,
            }
        )
    return json.dumps(
        {
            "generated_at_sgt": iso_sgt(now),
            "timezone": "Asia/Singapore",
            "sessions": payload,
        },
        ensure_ascii=False,
        indent=None if compact else 2,
        separators=(",", ":") if compact else None,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="claude-cache-watch",
        description="Estimate Claude Code prompt-cache TTL from local JSONL usage records.",
    )
    parser.add_argument("session", nargs="?", help="inspect one session by ID prefix")
    parser.add_argument(
        "--claude-dir",
        type=Path,
        default=Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser(),
        help="Claude data directory (default: CLAUDE_CONFIG_DIR or ~/.claude)",
    )
    parser.add_argument("--all", action="store_true", help="include inactive session history")
    parser.add_argument("--include-cli", action="store_true", help="include CLI sessions, not only Desktop")
    parser.add_argument("--limit", type=int, default=20, help="maximum sessions to display (default: 20)")
    parser.add_argument("--json", action="store_true", help="output JSON")
    parser.add_argument(
        "--watch",
        nargs="?",
        const=1.0,
        type=float,
        metavar="SECONDS",
        help="refresh continuously (default interval: 1 second)",
    )
    return parser


def run(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.limit <= 0:
        raise CliError("--limit must be greater than zero")
    if args.watch is not None and args.watch < 0.2:
        raise CliError("--watch interval must be at least 0.2 seconds")
    claude_dir = args.claude_dir.expanduser().resolve()
    if not claude_dir.is_dir():
        raise CliError(f"Claude data directory does not exist: {claude_dir}")

    cache = TranscriptCache()
    first_render = True
    while True:
        now = datetime.now(timezone.utc)
        sessions = collect_sessions(
            claude_dir,
            include_inactive=args.all,
            include_cli=args.include_cli,
            limit=args.limit,
            selector=args.session,
            cache=cache,
        )
        rendered = render_json(sessions, now, compact=args.watch is not None) if args.json else render_table(sessions, now)
        if args.watch is not None and not args.json and sys.stdout.isatty():
            sys.stdout.write("\033[2J\033[H")
        elif args.watch is not None and not first_render:
            sys.stdout.write("\n")
        print(rendered, flush=True)
        first_render = False
        if args.watch is None:
            return 0
        time.sleep(args.watch)


def main() -> None:
    try:
        raise SystemExit(run())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except CliError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
