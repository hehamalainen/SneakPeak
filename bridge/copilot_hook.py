#!/usr/bin/env python3
"""Copilot lifecycle observation. Returns no permission or loop-control decisions."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
from common import agent, atomic_json, short


def handle(event: dict, state: Path, kind: str):
    sid = event.get("sessionId") or event.get("session_id")
    if not isinstance(sid, str) or not sid:
        return {}
    aid = "copilot:" + sid
    try:
        feed = json.loads(state.read_text())
    except (OSError, ValueError):
        feed = {"agents": [], "missions": []}
    existing = next((a for a in feed.get("agents", []) if a["id"] == aid), None)
    cwd = event.get("cwd", "")
    a = dict(existing) if existing else agent(aid, aid, "GitHub Copilot · " + (Path(cwd).name or sid[:8]), "GitHub Copilot")
    a.update(sessionId=sid, workspace=cwd, sourceApp="GitHub Copilot", harnessId="copilot", lastActivity=time.time())
    mission = next((m for m in feed.get("missions", []) if m["id"] == a["missionId"]),
                   {"id": a["missionId"], "title": Path(cwd).name or "Copilot", "goal": "Define the outcome for this session", "checkpoints": []})
    if kind == "sessionStart":
        a.update(status="idle", request=None, summary="Copilot session connected · waiting for work")
        if event.get("initialPrompt"):
            mission["goal"] = short(event["initialPrompt"], 600)
    elif kind == "userPromptSubmitted":
        a.update(status="working", request=None, summary="Copilot is working toward the requested outcome")
    elif kind == "agentStop":
        a.update(status="done", request=None, summary="The Copilot agent loop finished. Review the outcome.")
    elif kind in {"postToolUseFailure", "errorOccurred"}:
        a.update(status="attention", summary="Copilot reported an error. Check its next update.")
    filename = "copilot-hook-" + hashlib.sha256(aid.encode()).hexdigest() + ".json"
    atomic_json(state.parent / "sources" / filename, {"generatedAt": time.time(), "missions": [mission], "agents": [a]})
    return {}  # No approvals, additional context, rewritten input, or forced continuation.


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--event", required=True, choices=["sessionStart", "userPromptSubmitted", "agentStop", "postToolUseFailure", "errorOccurred"])
    args = parser.parse_args()
    try:
        output = handle(json.load(sys.stdin), Path(args.state).resolve(), args.event)
    except (OSError, ValueError, KeyError, TypeError):
        output = {}
    print(json.dumps(output))
