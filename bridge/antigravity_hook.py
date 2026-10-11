#!/usr/bin/env python3
"""Observe Antigravity lifecycle events without changing permissions or loop flow."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from common import agent, atomic_json


def handle(event: dict, state: Path, kind: str):
    sid = event.get("conversationId")
    if not sid:
        return {} if kind != "Stop" else {"decision": "allow"}
    aid = "antigravity:" + sid
    try:
        feed = json.loads(state.read_text())
    except (OSError, ValueError):
        feed = {"agents": [], "missions": []}
    existing = next((a for a in feed["agents"] if a["id"] == aid), None)
    workspaces = event.get("workspacePaths") or []
    cwd = workspaces[0] if workspaces else ""
    a = dict(existing) if existing else agent(aid, aid, "Antigravity · " + (Path(cwd).name or sid[:8]), "Antigravity")
    a.update(sessionId=sid, lastActivity=time.time(), artifactPath=event.get("artifactDirectoryPath"), workspacePaths=workspaces)
    transcript = event.get("transcriptPath", "")
    a["sourceApp"] = "Antigravity IDE" if "antigravity-ide" in transcript else "Antigravity CLI" if "antigravity-cli" in transcript else "Antigravity"
    mission = next((m for m in feed["missions"] if m["id"] == a["missionId"]),
                   {"id": a["missionId"], "title": Path(cwd).name or "Antigravity", "goal": "Define the outcome for this session", "checkpoints": []})
    if kind == "PreInvocation":
        a.update(status="working", request=None, summary="The agent is preparing its next step")
    elif kind == "PostInvocation":
        a.update(status="observed", summary="A model update was observed · work may continue")
    elif kind == "PostToolUse":
        if event.get("error"):
            a.update(status="attention", summary="A tool step failed. Check Antigravity.")
        else:
            a.update(status="working", summary="A tool step completed · the agent is continuing", request=None)
    elif kind == "Stop":
        if event.get("error") or event.get("terminationReason") in {"error", "max_steps_exceeded"}:
            a.update(status="attention", summary="The agent stopped before a clean handoff. Check the session.", request=None)
        elif event.get("fullyIdle") is True:
            a.update(status="done", summary="The agent loop and background tasks have finished. Review the outcome.", request=None)
        else:
            a.update(status="working", summary="The foreground loop stopped; background tasks are still active", request=None)
    filename = "antigravity-hook-" + hashlib.sha256(aid.encode()).hexdigest() + ".json"
    atomic_json(state.parent / "sources" / filename, {"generatedAt": time.time(), "missions": [mission], "agents": [a]})
    # Stop allows the normal stop; other observer events inject or change nothing.
    return {"decision": "allow"} if kind == "Stop" else {}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--event", required=True, choices=["PreInvocation", "PostInvocation", "PostToolUse", "Stop"])
    args = parser.parse_args()
    try:
        result = handle(json.load(sys.stdin), Path(args.state).resolve(), args.event)
    except (OSError, ValueError, KeyError, TypeError):
        result = {"decision": "allow"} if args.event == "Stop" else {}
    print(json.dumps(result))
