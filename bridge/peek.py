#!/usr/bin/env python3
"""SneakPeek observer, demo, and explicit mission checkpoint publisher."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import time
from common import agent, atomic_json, read_decision, request, fresh_timestamp, workspace_in_scope
from validation import agent as valid_agent, mission as valid_mission, number
from observer import Observer
from harnesses import Registry, register


def mission_filename(mission_id: str) -> str:
    return hashlib.sha256(mission_id.encode()).hexdigest() + ".json"


class Demo:
    def __init__(self):
        self.started = time.time()
        self.pending = request("Run the final integration check?",
                               "Validation will run a local test suite against the event bridge. No files are published and no external account is changed.", ttl=3600)
        self.answer = None

    def feed(self, directory: Path):
        now = time.time()
        answer = read_decision(directory / "decisions", self.pending, "demo-validation")
        if answer:
            self.answer = answer
        mission = {"id": "demo-mission", "title": "SneakPeek", "goal": "Know when your agents need you. Keep your focus the rest of the time.",
                   "checkpoints": [
                       {"id": "glance", "label": "A quiet, readable glance", "status": "verified", "evidence": "Hover and collapse reviewed on a Mac display.", "source": "human"},
                       {"id": "bridge", "label": "Both agents visible in one place", "status": "reported", "evidence": "Codex and Claude events arrive in the same local feed.", "source": "agent"},
                       {"id": "decision", "label": "A decision reaches the waiting agent", "status": "reported" if self.answer else "pending", "evidence": "The demo agent received your decision." if self.answer else "Waiting for the integration check.", "source": "agent"}]}
        design = agent("demo-design", mission["id"], "Interface", "Claude")
        design.update(status="done", lastActivity=self.started, lastProgress=self.started,
                      summary="The glance view is ready for review.", evidence="The quiet view and hover view are connected.",
                      trajectory="onCourse", nextStep="Check the layout on your screen")
        bridge = agent("demo-bridge", mission["id"], "Integration", "Codex")
        bridge.update(status="working", summary="Connecting session updates to the mission view.",
                      evidence="Both provider fixtures pass the event parser.", lastProgress=self.started,
                      trajectory="onCourse", nextStep="Exercise the approval return path")
        validation = agent("demo-validation", mission["id"], "Validation", "Codex")
        validation.update(status="done" if self.answer else "attention",
                          summary=("Decision received. The demo check is complete." if self.answer == "accept" else
                                   "Decision received. The demo check was declined." if self.answer else "One permission is holding the final check."),
                          evidence="Your reply reached this demo agent." if self.answer else "Ready to run the integration check.",
                          trajectory="onCourse", nextStep="Review the result" if self.answer else "Allow or decline the local check",
                          request=None if self.answer else self.pending)
        research = agent("demo-research", mission["id"], "Research", "Antigravity")
        research.update(status="observed", summary="A progress update is ready to peek at.",
                        evidence="The lifecycle hook distinguishes a step from a finished agent loop.",
                        trajectory="unknown", nextStep="Review the mission's remaining landing checks")
        return {"generatedAt": now, "demo": True, "missions": [mission], "agents": [validation, bridge, design, research], "warnings": []}


def merge_feed(missions, agents, directory: Path, harnesses=None, recent_hours=24, project=None):
    warnings = []
    by_id = {a["id"]: a for a in agents}
    mission_map = {m["id"]: m for m in missions}
    for path in (directory / "sources").glob("*.json"):
        try:
            source = json.loads(path.read_text())
            if not isinstance(source, dict) or not isinstance(source.get("missions", []), list) or not isinstance(source.get("agents", []), list):
                raise ValueError("Expected source lists")
            authority = source.get("managed") is True and source.get("active") is True and fresh_timestamp(source.get("generatedAt"), max_age=15)
            connected = []
            for raw in source.get("agents", []):
                try:
                    a = valid_agent(raw)
                except ValueError:
                    warnings.append("An invalid connected agent was skipped")
                    continue
                if workspace_in_scope(a.get("workspace"), project):
                    connected.append(a)
            connected_missions = {a["missionId"] for a in connected}
            for m in source.get("missions", []):
                try:
                    m = valid_mission(m)
                except ValueError:
                    warnings.append("An invalid connected mission was skipped")
                    continue
                if m["id"] in connected_missions and (m["id"] not in mission_map or authority):
                    mission_map[m["id"]] = m
            for a in connected:
                hid = a.get("harnessId") or a["id"].split(":")[0]
                a["harnessId"] = hid
                if harnesses and any(h["id"] == hid and not h["enabled"] for h in harnesses):
                    continue
                if time.time() - a["lastActivity"] > recent_hours * 3600:
                    continue
                if a.get("request") and a["request"].get("mode") == "decision":
                    if time.time() > a["request"]["expiresAt"] or not fresh_timestamp(source.get("generatedAt"), max_age=15):
                        a.update(request=None, status="attention", summary="Approval connection expired. Return to the source session.")
                observed = by_id.get(a["id"])
                if observed is None or a.get("request") or authority or a["lastActivity"] >= observed["lastActivity"]:
                    by_id[a["id"]] = a
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("One connected source could not be read")
    for path in (directory / "progress").glob("*.json"):
        try:
            progress = json.loads(path.read_text())
            if not isinstance(progress, dict) or not number(progress.get("at")) or not all(isinstance(progress.get(k), str) for k in ("agentId", "evidence", "trajectory", "nextStep")):
                raise ValueError("Invalid progress")
            a = by_id.get(progress["agentId"])
            if a and progress["at"] >= a.get("lastProgress", 0):
                a.update(evidence=progress["evidence"], lastProgress=progress["at"],
                         trajectory=progress["trajectory"], nextStep=progress["nextStep"])
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("A progress checkpoint could not be read")
    for mid in list(mission_map):
        path = directory / "missions" / mission_filename(mid)
        try:
            override = valid_mission(json.loads(path.read_text()))
            if override["id"] == mid:
                mission_map[mid] = override
        except FileNotFoundError:
            pass
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("A saved mission could not be read")
    active_missions = {a["missionId"] for a in by_id.values()}
    catalog = [dict(h) for h in harnesses or []]
    for h in catalog:
        h["sessionCount"] = sum(a.get("harnessId") == h["id"] for a in by_id.values())
        if h["sessionCount"] and h["enabled"]:
            h.update(status="ready", detail=f"{h['sessionCount']} observed agents · local connection ready")
            if h.get("omittedLogs", 0):
                h["detail"] += f" · {h['omittedLogs']} recent logs omitted; coverage is incomplete"
        if h.get("omittedLogs", 0):
            warnings.append(f"{h['name']}: {h['omittedLogs']} recent logs omitted; monitoring coverage is incomplete")
    return {"generatedAt": time.time(), "demo": False, "harnesses": catalog,
            "projectRoot": str(Path(project).resolve()) if project else None,
            "missions": [m for mid, m in mission_map.items() if mid in active_missions],
            "agents": sorted(by_id.values(), key=lambda a: (a["status"] != "attention", -a["lastActivity"])),
            "warnings": warnings}


def watch(args):
    path = Path(args.state).resolve()
    directory = path.parent
    observer, demo = Observer(Path(args.home).expanduser(), args.project, directory), Demo()
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while running:
        if getattr(args, "owner_pid", 0) and os.getppid() != args.owner_pid:
            break
        missions, agents = observer.refresh()
        feed = merge_feed(missions, agents, directory, observer.catalog, observer.registry.recent_hours, observer.project)
        feed["warnings"].extend(observer.registry.warnings)
        atomic_json(path, feed)
        atomic_json(directory / "demo-state.json", demo.feed(directory))
        if args.once:
            break
        time.sleep(1)


def register_command(args):
    value = register(Path(args.state).resolve().parent, args.name, args.events, args.format)
    print(json.dumps(value, indent=2))


def emit(args):
    directory = Path(args.state).resolve().parent
    registry = Registry(Path.home(), directory)
    definition = next((h for h in registry.definitions if h["id"] == args.harness), None)
    if not definition or definition["format"] != "sneakpeek":
        raise SystemExit("Register a harness using the sneakpeek event format first.")
    if len(definition["logs"]) != 1 or any(c in definition["logs"][0] for c in "*?["):
        raise SystemExit("Publishing needs one concrete event file, not a wildcard path.")
    path = Path(registry.expand(definition["logs"][0]))
    value = {"schema": 1, "event": args.event, "session_id": args.session, "timestamp": time.time(),
             "summary": args.summary, "goal": args.goal, "evidence": args.evidence,
             "next_step": args.next, "trajectory": args.trajectory, "cwd": args.project,
             "parent_session_id": args.parent, "name": args.agent_name}
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(value, ensure_ascii=False) + "\n")
    print("Event published to " + str(path))


def checkpoint(args):
    directory = Path(args.state).resolve().parent
    feed = json.loads(Path(args.state).read_text())
    a = next((a for a in feed["agents"] if a["id"] == args.agent), None)
    if a is None:
        raise SystemExit("Agent not found. Use its id from the live state file.")
    filename = hashlib.sha256(a["id"].encode()).hexdigest() + ".json"
    if args.checkpoint:
        mission = next(m for m in feed["missions"] if m["id"] == a["missionId"])
        folder = directory / "missions"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / mission_filename(mission["id"])
        # Several agents can report checks before the next observer refresh.
        # Merge against the latest saved plan, not the lagging live snapshot.
        with path.with_suffix(".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if path.exists():
                saved = json.loads(path.read_text())
                if saved.get("id") == mission["id"]:
                    if saved.get("definitionRevision", 0) != mission.get("definitionRevision", 0) or saved.get("goal") != mission.get("goal"):
                        raise SystemExit("Mission changed. Refresh before reporting this landing check.")
                    mission = saved
            check = next((c for c in mission["checkpoints"] if c["id"] == args.checkpoint), None)
            if check is None:
                raise SystemExit("Landing check not found. Use a checkpoint id from the state file.")
            check.update(status="reported", evidence=args.evidence, source="agent")
            atomic_json(path, mission)
    atomic_json(directory / "progress" / filename,
                {"agentId": a["id"], "at": time.time(), "evidence": args.evidence,
                 "trajectory": args.trajectory, "nextStep": args.next})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    monitor = sub.add_parser("watch")
    monitor.add_argument("--state", default="runtime/state.json")
    monitor.add_argument("--home", default=str(Path.home()))
    monitor.add_argument("--project", help="Optional exact project directory scope")
    monitor.add_argument("--once", action="store_true")
    monitor.add_argument("--owner-pid", type=int, default=0, help="Stop when the owning app process exits")
    monitor.set_defaults(handler=watch)
    progress = sub.add_parser("checkpoint")
    progress.add_argument("--state", default="runtime/state.json")
    progress.add_argument("--agent", required=True)
    progress.add_argument("--evidence", required=True)
    progress.add_argument("--next", required=True)
    progress.add_argument("--trajectory", choices=["unknown", "onCourse", "atRisk"], default="unknown")
    progress.add_argument("--checkpoint", help="Optional landing-check id to attach reported evidence to")
    progress.set_defaults(handler=checkpoint)
    registration = sub.add_parser("register", help="Add a harness without rebuilding the app")
    registration.add_argument("--state", default="runtime/state.json")
    registration.add_argument("--name", required=True)
    registration.add_argument("--events", help="Absolute event file or log glob; defaults to a new local event file")
    registration.add_argument("--format", choices=["sneakpeek", "codex", "claude", "copilot", "antigravity"], default="sneakpeek")
    registration.set_defaults(handler=register_command)
    publisher = sub.add_parser("emit", help="Publish a standard lifecycle or progress event")
    publisher.add_argument("--state", default="runtime/state.json")
    publisher.add_argument("--harness", required=True)
    publisher.add_argument("--session", required=True)
    publisher.add_argument("--event", choices=["started", "activity", "progress", "needs_input", "resolved", "completed", "failed"], required=True)
    publisher.add_argument("--summary", default="")
    publisher.add_argument("--goal", default="")
    publisher.add_argument("--evidence", default="")
    publisher.add_argument("--next", default="")
    publisher.add_argument("--trajectory", choices=["unknown", "onCourse", "atRisk"], default="unknown")
    publisher.add_argument("--project", default="")
    publisher.add_argument("--parent")
    publisher.add_argument("--agent-name")
    publisher.set_defaults(handler=emit)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
