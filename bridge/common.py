"""Local, dependency-free transport shared by observers and approval adapters."""
from __future__ import annotations
import json
import math
import os
import re
from pathlib import Path
import tempfile
import time
import uuid


def default_state_path() -> Path:
    """Keep supervision state outside a supervised checkout by default."""
    return Path.home() / "Library" / "Application Support" / "SneakPeek" / "state.json"


def fresh_timestamp(value, *, max_age: float = 10) -> bool:
    try:
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and math.isfinite(value) and -5 <= time.time() - value <= max_age)
    except OverflowError:
        return False


def workspace_in_scope(workspace, project) -> bool:
    if not project:
        return True
    return (isinstance(workspace, str) and bool(workspace)
            and Path(workspace).resolve().is_relative_to(Path(project).resolve()))


def approval_surface_available(state: Path, provider: str, workspace: str) -> bool:
    """Collector liveness alone never authorizes an inline approval workflow."""
    try:
        feed = json.loads(state.read_text())
        surface = json.loads((state.parent / "approval-surface.json").read_text())
        return (isinstance(feed, dict) and isinstance(surface, dict)
                and fresh_timestamp(feed.get("generatedAt"))
                and feed.get("demo", False) is False
                and fresh_timestamp(surface.get("generatedAt"))
                and surface.get("live") is True
                and surface.get("statePath") == str(state.resolve())
                and surface.get("provider") in {"All sources", provider}
                and workspace_in_scope(workspace, feed.get("projectRoot")))
    except (OSError, ValueError, TypeError, AttributeError):
        return False


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".peek-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, ensure_ascii=False)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def request(title: str, detail: str, *, mode: str = "decision", ttl: float = 300) -> dict:
    issued = time.time()
    return {"id": str(uuid.uuid4()), "issuedAt": issued, "title": title, "detail": detail,
            "choices": [{"id": "accept", "label": "Allow once"},
                        {"id": "decline", "label": "Decline"}] if mode == "decision" else [],
            "mode": mode, "expiresAt": issued + ttl}


def read_decision(directory: Path, pending: dict, agent_id: str, *, trusted_local_inline=False) -> str | None:
    """A reply is scoped to the exact outstanding request and has a short lifetime."""
    if not trusted_local_inline:
        return None
    try:
        now = time.time()
        issued, expiry = pending["issuedAt"], pending["expiresAt"]
        def timestamp(value):
            return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
        if not timestamp(issued) or not timestamp(expiry) or not issued <= now < expiry:
            return None
        uuid.UUID(pending["id"])
        data = json.loads((directory / (pending["id"] + ".json")).read_text())
        created = data["createdAt"]
        valid = (data["requestId"] == pending["id"] and data["agentId"] == agent_id
                 and timestamp(created) and issued <= created <= min(expiry, now + 5)
                 and data["choiceId"] in {c["id"] for c in pending["choices"]})
        return data["choiceId"] if valid else None
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
        return None


def agent(agent_id: str, mission_id: str, name: str, provider: str) -> dict:
    now = time.time()
    return {"id": agent_id, "missionId": mission_id, "name": name, "provider": provider,
            "status": "idle", "summary": "Waiting for a session update", "lastActivity": now,
            "lastProgress": 0, "evidence": "No checkpoint reported yet",
            "nextStep": "Set a clear definition of done", "trajectory": "unknown",
            "sessionId": None, "request": None}


def short(text: str, limit: int = 220) -> str:
    # Only visible messages, never private reasoning or raw tool output.
    # Compact display excerpts only. Raw approval tool inputs bypass this helper.
    text = re.sub(r"!\[([^]\n]*)\]\([^)\n]*\)", r"\1", text)
    text = re.sub(r"\[([^]\n]+)\]\([^)\n]*\)", r"\1", text)
    text = re.sub(r"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+)", "", text)
    text = re.sub(r"(`{1,3}|\*\*|__|~~)(.+?)\1", r"\2", text, flags=re.S)
    return " ".join(text.strip().split())[:limit]


def text_content(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return " ".join(c.get("text", "") for c in content if isinstance(c, dict)
                    and c.get("type") in {"text", "input_text", "output_text"})
