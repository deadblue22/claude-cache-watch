import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from claude_cache_watch import cache_status, parse_transcript, remaining_text, session_from_transcript


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")


def assistant(timestamp: str, request_id: str, *, read: int, one_hour: int = 0, five_minute: int = 0) -> dict:
    return {
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": request_id,
        "sessionId": "embedded-parent-id",
        "cwd": "/tmp/project",
        "entrypoint": "claude-desktop",
        "slug": "test-session",
        "message": {
            "id": f"message-{request_id}",
            "usage": {
                "cache_read_input_tokens": read,
                "cache_creation_input_tokens": one_hour + five_minute,
                "cache_creation": {
                    "ephemeral_1h_input_tokens": one_hour,
                    "ephemeral_5m_input_tokens": five_minute,
                },
            },
        },
    }


class TestClaudeCacheWatch(unittest.TestCase):
    def test_uses_filename_as_session_id_and_detects_one_hour_ttl(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "actual-session-id.jsonl"
            write_jsonl(
                path,
                [
                    {"type": "user", "timestamp": "2026-09-04T07:00:00Z"},
                    assistant("2026-09-04T07:00:04Z", "request-1", read=1200, one_hour=30),
                    assistant("2026-09-04T07:00:08Z", "request-1", read=1200, one_hour=30),
                    {"type": "custom-title", "customTitle": "Cache monitor"},
                    {
                        "type": "last-prompt",
                        "sessionId": "actual-session-id",
                        "lastPrompt": "  simplify\n  the   interface  ",
                    },
                    {
                        "type": "last-prompt",
                        "sessionId": "actual-session-id",
                        "lastPrompt": "<local-command-caveat>generated content</local-command-caveat>",
                    },
                    {
                        "type": "last-prompt",
                        "sessionId": "parent-session-id",
                        "lastPrompt": "inherited parent prompt",
                    },
                ],
            )

            result = parse_transcript(path)

            self.assertEqual(result.session_id, "actual-session-id")
            self.assertEqual(result.title, "Cache monitor")
            self.assertEqual(result.last_prompt, "simplify the interface")
            self.assertIsNotNone(result.cache_request)
            assert result.cache_request is not None
            self.assertEqual(result.cache_request.ttls, ("1h",))
            self.assertEqual(result.cache_request.started_after.isoformat(), "2026-09-04T07:00:00+00:00")
            self.assertEqual(result.cache_request.started_before.isoformat(), "2026-09-04T07:00:04+00:00")

    def test_tracks_last_real_model_for_current_session(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "session.jsonl"
            current = assistant("2026-09-04T07:00:01Z", "request-1", read=100)
            current["sessionId"] = "session"
            current["message"]["model"] = "claude-opus-4-6"
            synthetic = assistant("2026-09-04T07:00:02Z", "request-2", read=100)
            synthetic["sessionId"] = "session"
            synthetic["message"]["model"] = "<synthetic>"
            inherited = assistant("2026-09-04T07:00:03Z", "request-3", read=100)
            inherited["sessionId"] = "parent-session"
            inherited["message"]["model"] = "claude-sonnet-4-6"
            write_jsonl(path, [current, synthetic, inherited])

            self.assertEqual(parse_transcript(path).model, "claude-opus-4-6")

    def test_latest_cache_request_refreshes_expiry(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "session.jsonl"
            write_jsonl(
                path,
                [
                    {"type": "user", "timestamp": "2026-09-04T07:00:00Z"},
                    assistant("2026-09-04T07:00:01Z", "request-1", read=100, five_minute=20),
                    {"type": "user", "timestamp": "2026-09-04T07:03:00Z"},
                    assistant("2026-09-04T07:03:02Z", "request-2", read=120, five_minute=10),
                ],
            )
            transcript = parse_transcript(path)
            session = session_from_transcript(transcript, None)
            now = datetime(2026, 9, 4, 7, 7, 0, tzinfo=timezone.utc)

            self.assertIsNotNone(transcript.cache_request)
            assert transcript.cache_request is not None
            self.assertEqual(transcript.cache_request.request_id, "request-2")
            self.assertEqual(cache_status(session, now), "VALID")
            self.assertEqual(remaining_text(transcript.cache_request, now), "1m00s-1m02s")

    def test_infers_ttl_for_read_only_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "session.jsonl"
            write_jsonl(
                path,
                [
                    {"type": "user", "timestamp": "2026-09-04T07:00:00Z"},
                    assistant("2026-09-04T07:00:01Z", "request-1", read=0, one_hour=200),
                    {"type": "user", "timestamp": "2026-09-04T07:10:00Z"},
                    assistant("2026-09-04T07:10:02Z", "request-2", read=220),
                ],
            )

            request = parse_transcript(path).cache_request

            self.assertIsNotNone(request)
            assert request is not None
            self.assertEqual(request.ttls, ("1h",))
            self.assertEqual(request.ttl_source, "inferred-from-earlier-usage")

    def test_marks_expired_cache(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "session.jsonl"
            write_jsonl(
                path,
                [
                    {"type": "user", "timestamp": "2026-09-04T07:00:00Z"},
                    assistant("2026-09-04T07:00:01Z", "request-1", read=100, five_minute=20),
                ],
            )
            transcript = parse_transcript(path)
            session = session_from_transcript(transcript, None)

            now = datetime(2026, 9, 4, 7, 6, tzinfo=timezone.utc)
            self.assertEqual(cache_status(session, now), "EXPIRED")


if __name__ == "__main__":
    unittest.main()
