#!/usr/bin/env python3
"""A per-session Claude PermissionRequest hook; never grants blanket permission."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from common import agent, atomic_json, read_decision, request


def handle(event: dict, state: Path, timeout: float = 120) -> dict:
    if event.get("hook_event_name") != "PermissionRequest":
        return {}
    directory = state.parent
    try:
        feed = json.loads(state.read_text())
        if time.time() - feed["generatedAt"] > 10:
            return {}  # Keep the original approval flow if SneakPeek is not running.
    except (OSError, ValueError, KeyError):
        return {}
    sid = event.get("session_id", "")
    if not sid:
        return {}
    aid = "claude:" + sid
    existing = next((a for a in feed.get("agents", []) if a["id"] == aid), None)
    a = dict(existing) if existing else agent(aid, aid, "Claude · " + Path(event.get("cwd", "")).name, "Claude")
    a["sessionId"] = sid
    mission = next((m for m in feed.get("missions", []) if m["id"] == a["missionId"]),
                   {"id": a["missionId"], "title": "Claude Code", "goal": "Define the outcome for this session", "checkpoints": []})
    tool = event.get("tool_name", "Tool")
    # Show the complete tool input. A truncated command must never be approved.
    detail = "Tool: " + tool + "\nProject: " + event.get("cwd", "") + "\n\n" + json.dumps(event.get("tool_input", {}), indent=2, ensure_ascii=False)
    pending = request(f"Allow {tool} for this step?", detail, ttl=timeout)
    a.update(status="attention", summary="A permission is waiting for your decision", request=pending, lastActivity=time.time())
    source = directory / "sources" / ("claude-request-" + hashlib.sha256(aid.encode()).hexdigest() + ".json")

    def publish():
        atomic_json(source, {"generatedAt": time.time(), "missions": [mission], "agents": [a]})

    while time.time() < pending["expiresAt"]:
        publish()
        answer = read_decision(directory / "decisions", pending, aid)
        if answer:
            a.update(request=None, status="working", summary="Decision received · returning to Claude", lastActivity=time.time())
            publish()
            behavior = "allow" if answer == "accept" else "deny"
            decision = {"behavior": behavior}
            if behavior == "deny":
                decision["message"] = "The user declined this step in SneakPeek."
            return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}
        # If the observer goes away, hand back immediately to Claude's own prompt.
        try:
            if time.time() - json.loads(state.read_text())["generatedAt"] > 10:
                break
        except (OSError, ValueError, KeyError):
            break
        time.sleep(0.25)
    a.update(request=None, status="attention", summary="Permission returned to Claude. Answer in the source session.", lastActivity=time.time())
    publish()
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    args = parser.parse_args()
    try:
        event = json.load(sys.stdin)
        result = handle(event, Path(args.state).resolve())
    except (OSError, ValueError, KeyError, TypeError):
        result = {}  # No JSON decision means normal Claude permission handling.
    print(json.dumps(result))


if __name__ == "__main__":
    main()
