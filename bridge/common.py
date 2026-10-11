"""Local, dependency-free transport shared by observers and approval adapters."""
from __future__ import annotations
import json
import os
from pathlib import Path
import tempfile
import time
import uuid


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
    return {"id": str(uuid.uuid4()), "title": title, "detail": detail,
            "choices": [{"id": "accept", "label": "Allow once"},
                        {"id": "decline", "label": "Decline"}] if mode == "decision" else [],
            "mode": mode, "expiresAt": time.time() + ttl}


def read_decision(directory: Path, pending: dict, agent_id: str) -> str | None:
    """A reply is scoped to the exact outstanding request and has a short lifetime."""
    if time.time() >= pending["expiresAt"]:
        return None
    try:
        uuid.UUID(pending["id"])
        data = json.loads((directory / (pending["id"] + ".json")).read_text())
        valid = (data["requestId"] == pending["id"] and data["agentId"] == agent_id
                 and pending["expiresAt"] - 3600 <= data["createdAt"] <= time.time() + 5
                 and data["choiceId"] in {c["id"] for c in pending["choices"]})
        return data["choiceId"] if valid else None
    except (OSError, ValueError, KeyError, TypeError):
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
    return " ".join(text.strip().split())[:limit]


def text_content(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return " ".join(c.get("text", "") for c in content if isinstance(c, dict)
                    and c.get("type") in {"text", "input_text", "output_text"})
