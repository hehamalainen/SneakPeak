#!/usr/bin/env python3
"""A per-session Claude PermissionRequest hook; never grants blanket permission."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from common import agent, atomic_json, read_decision, request, approval_surface_available


def handle(event: dict, state: Path, timeout: float = 120, *, trusted_local_inline=False) -> dict:
    # Unsigned peer-written files are never executable permissions by default.
    if not trusted_local_inline or event.get("hook_event_name") != "PermissionRequest":
        return {}
    directory = state.parent
    if not approval_surface_available(state, "Claude", event.get("cwd", "")):
        return {}
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
    a.update(sessionId=sid, workspace=event.get("cwd", ""))
    mission = next((m for m in feed.get("missions", []) if m["id"] == a["missionId"]),
                   {"id": a["missionId"], "title": "Claude Code", "goal": "Define the outcome for this session", "checkpoints": []})
    tool = event.get("tool_name", "Tool")
    # Show the complete tool input. A truncated command must never be approved.
    detail = "Tool: " + tool + "\nProject: " + event.get("cwd", "") + "\n\n" + json.dumps(event.get("tool_input", {}), indent=2, ensure_ascii=False)
    pending = request(f"Allow {tool} for this step?", detail, ttl=timeout)
    pending["transport"] = "trusted-local-file"
    a.update(status="attention", summary="A permission is waiting for your decision", request=pending, lastActivity=time.time())
    source = directory / "sources" / ("claude-request-" + hashlib.sha256(aid.encode()).hexdigest() + ".json")

    def publish():
        atomic_json(source, {"generatedAt": time.time(), "missions": [mission], "agents": [a]})

    while time.time() < pending["expiresAt"]:
        publish()
        answer = read_decision(directory / "decisions", pending, aid, trusted_local_inline=trusted_local_inline)
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
            if not approval_surface_available(state, "Claude", event.get("cwd", "")):
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
    parser.add_argument("--trusted-local-inline", action="store_true", help="Opt in to unsigned local permissions; any writer of this state can forge a reply")
    args = parser.parse_args()
    try:
        event = json.load(sys.stdin)
        result = handle(event, Path(args.state).resolve(), trusted_local_inline=args.trusted_local_inline)
    except (OSError, ValueError, KeyError, TypeError):
        result = {}  # No JSON decision means normal Claude permission handling.
    print(json.dumps(result))


if __name__ == "__main__":
    main()
