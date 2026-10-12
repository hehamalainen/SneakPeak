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
import uuid
from common import default_state_path, agent, atomic_json, read_decision, request, fresh_timestamp, workspace_in_scope
from validation import agent as valid_agent, mission as valid_mission, number
from observer import Observer
from harnesses import Registry, register
from mission_tracking import project as project_missions, add_evidence, revision, definition_revision, fingerprint


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
        answer = read_decision(directory / "decisions", self.pending, "demo-validation", trusted_local_inline=True)
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
    by_id = {a["id"]: dict(a, provenance="observed-log") for a in agents}
    observed_by_id = dict(by_id)
    mission_map = {m["id"]: m for m in missions}
    for path in (directory / "sources").glob("*.json"):
        try:
            source = json.loads(path.read_text())
            if not isinstance(source, dict) or not isinstance(source.get("missions", []), list) or not isinstance(source.get("agents", []), list):
                raise ValueError("Expected source lists")
            # A local JSON lease is liveness, never authenticated source authority.
            # Keep observed goals and concerns even if a source claims managed=True.
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
                if m["id"] in connected_missions and m["id"] not in mission_map:
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
                observed = observed_by_id.get(a["id"])
                current = by_id.get(a["id"])
                a["provenance"] = "local-source"
                if current is None:
                    by_id[a["id"]] = a
                elif a.get("request") or a["lastActivity"] >= current["lastActivity"]:
                    merged = dict(a)
                    # An unsigned file cannot clear an observed unresolved request or
                    # attention state. Wait for the log to corroborate resolution.
                    if observed and (observed.get("request") or observed["status"] == "attention"):
                        merged.update(request=observed.get("request"), status=observed["status"],
                                      summary=observed["summary"])
                    # New activity is not new evidence. Source claims cannot hide a
                    # log-observed concern or overwrite more recent observed progress.
                    if observed and (observed.get("trajectory") == "atRisk" or observed.get("lastProgress", 0) >= a.get("lastProgress", 0)):
                        for field in ("lastProgress", "evidence", "trajectory", "nextStep"):
                            merged[field] = observed[field]
                    if observed and (((observed.get("request") or observed["status"] == "attention") and
                            (a.get("request") != observed.get("request") or a["status"] != observed["status"])) or (observed.get("trajectory") == "atRisk" and a.get("trajectory") != "atRisk")):
                        warnings.append("A local source conflicts with an observed concern; inspect the source session")
                    by_id[a["id"]] = merged
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("One connected source could not be read")
    for path in (directory / "progress").glob("*.json"):
        try:
            progress = json.loads(path.read_text())
            if not isinstance(progress, dict) or not number(progress.get("at")) or not all(isinstance(progress.get(k), str) for k in ("agentId", "evidence", "trajectory", "nextStep")):
                raise ValueError("Invalid progress")
            a = by_id.get(progress["agentId"])
            if a and progress["at"] >= a.get("lastProgress", 0):
                if observed_by_id.get(a["id"], {}).get("trajectory") == "atRisk" and progress["trajectory"] != "atRisk":
                    warnings.append("A progress report conflicts with an observed concern; inspect the source session")
                    continue
                a.update(evidence=progress["evidence"], lastProgress=progress["at"],
                         trajectory=progress["trajectory"], nextStep=progress["nextStep"])
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("A progress checkpoint could not be read")
    pinned = set()
    for mid, mission in mission_map.items():
        workspaces = {a.get("workspace") for a in by_id.values() if a["missionId"] == mid and a.get("workspace")}
        if workspaces:
            mission["workspace"] = str(Path(project).resolve()) if project else next(iter(workspaces)) if len(workspaces) == 1 else None
    for path in (directory / "missions").glob("*.json"):
        try:
            override = valid_mission(json.loads(path.read_text()))
            mid = override["id"]
            scope = override.get("workspace") or mission_map.get(mid, {}).get("workspace")
            if path.name == mission_filename(mid) and (mid in mission_map or override.get("pinned")) and workspace_in_scope(scope, project):
                mission_map[mid] = override
                if override.get("pinned"):
                    pinned.add(mid)
        except FileNotFoundError:
            pass
        except (OSError, ValueError, KeyError, TypeError):
            warnings.append("A saved mission could not be read")
    # Course labels are claims with a freshness window, not durable facts.
    now = time.time()
    for a in by_id.values():
        at = a.get("lastProgress", 0)
        if a.get("trajectory") in {"onCourse", "atRisk"} and (not at or now - at > 3600 or at > now + 5):
            a["reportedTrajectory"] = a["trajectory"]
            a["trajectory"] = "unknown"
            a["progressFreshness"] = "stale"
        else:
            a["progressFreshness"] = "current" if at else "missing"
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
        if h.get("unscopedSessions", 0):
            detail = f"{h['unscopedSessions']} observed sessions lack a reported workspace and were excluded by the project filter"
            h["detail"] += " · " + detail
            warnings.append(f"{h['name']}: {detail}; project coverage is incomplete")
    return {"generatedAt": time.time(), "demo": False, "harnesses": catalog,
            "projectRoot": str(Path(project).resolve()) if project else None,
            "missions": [m for mid, m in mission_map.items() if mid in active_missions or mid in pinned],
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
        atomic_json(path, project_missions(feed, directory))
        example = demo.feed(directory)
        decorate_demo(example, demo.started)
        atomic_json(directory / "demo-state.json", project_missions(example, directory))
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
        mission = next((m for m in feed["missions"] if m["id"] == a["missionId"]), None)
        if mission is None:
            raise SystemExit("Mission not found. Refresh the session before reporting a landing check.")
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
                    if definition_revision(saved) != definition_revision(mission):
                        raise SystemExit("Mission changed. Refresh before reporting this landing check.")
                    mission = saved
            check = next((c for c in mission["checkpoints"] if c["id"] == args.checkpoint), None)
            if check is None:
                raise SystemExit("Landing check not found. Use a checkpoint id from the state file.")
            check.update(status="reported", evidence=args.evidence, source="agent")
            atomic_json(path, mission)
            if getattr(args, "reference", None):
                add_evidence(directory, mission, args.checkpoint, args.evidence, args.reference,
                             getattr(args, "claim", "supports"), args.agent)

    atomic_json(directory / "progress" / filename,
                {"agentId": a["id"], "at": time.time(), "evidence": args.evidence,
                 "trajectory": args.trajectory, "nextStep": args.next})


def evidence_command(args):
    state = Path(args.state).resolve()
    feed = json.loads(state.read_text())
    mission = next((m for m in feed["missions"] if m["id"] == args.mission), None)
    if mission is None:
        raise SystemExit("Mission not found in the live feed")
    result = add_evidence(state.parent, mission, args.checkpoint, args.summary,
                          args.reference, args.claim, args.actor)
    print(json.dumps(result, indent=2))


def decorate_demo(feed, started):
    """Trusted, clearly labeled example records; never used by real-source feeds."""
    mission = feed["missions"][0]
    mission["owner"] = "You"
    mission["evidenceMaxAgeSeconds"] = 86400
    rev = revision(mission)
    for i, check in enumerate(mission["checkpoints"]):
        if i == 2:
            continue  # One missing check makes uncertainty visible.
        record = {"id": str(uuid.UUID(int=100 + i)), "missionId": mission["id"],
                  "checkpointId": check["id"], "goalRevision": rev, "summary": check["evidence"],
                  "reference": "demo://check/" + check["id"], "verdict": "supports", "source": "report",
                  "actor": "Example agent", "observedAt": started, "digest": None}
        if i == 0:
            record["exampleReview"] = {"evidenceId": record["id"], "goalRevision": rev,
                                      "fingerprint": fingerprint(record), "verdict": "accept", "createdAt": started}
        check["exampleEvidence"] = [record]
    mission["exampleTaste"] = [{"id": str(uuid.UUID(int=200)), "missionId": mission["id"],
                               "goalRevision": rev, "valence": "off", "strength": "hunch",
                               "note": "The flow works, but it feels a little too demanding. I want it to feel calmer.",
                               "impact": "review", "acceptance": "unassessed", "createdAt": started,
                               "source": "human", "checkpointId": None}]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    monitor = sub.add_parser("watch")
    monitor.add_argument("--state", default=str(default_state_path()))
    monitor.add_argument("--home", default=str(Path.home()))
    monitor.add_argument("--project", help="Optional exact project directory scope")
    monitor.add_argument("--once", action="store_true")
    monitor.add_argument("--owner-pid", type=int, default=0, help="Stop when the owning app process exits")
    monitor.set_defaults(handler=watch)
    progress = sub.add_parser("checkpoint")
    progress.add_argument("--state", default=str(default_state_path()))
    progress.add_argument("--agent", required=True)
    progress.add_argument("--evidence", required=True)
    progress.add_argument("--next", required=True)
    progress.add_argument("--trajectory", choices=["unknown", "onCourse", "atRisk"], default="unknown")
    progress.add_argument("--checkpoint", help="Optional landing-check id to attach reported evidence to")
    progress.add_argument("--reference", help="Inspectable evidence file or HTTPS URL")
    progress.add_argument("--claim", choices=["supports", "contradicts", "unknown"], default="supports")
    progress.set_defaults(handler=checkpoint)
    registration = sub.add_parser("register", help="Add a harness without rebuilding the app")
    registration.add_argument("--state", default=str(default_state_path()))
    registration.add_argument("--name", required=True)
    registration.add_argument("--events", help="Absolute event file or log glob; defaults to a new local event file")
    registration.add_argument("--format", choices=["sneakpeek", "codex", "claude", "copilot", "antigravity"], default="sneakpeek")
    registration.set_defaults(handler=register_command)
    publisher = sub.add_parser("emit", help="Publish a standard lifecycle or progress event")
    publisher.add_argument("--state", default=str(default_state_path()))
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
    proof = sub.add_parser("evidence", help="Attach an inspectable evidence record to a mission check")
    proof.add_argument("--state", default=str(default_state_path()))
    proof.add_argument("--mission", required=True)
    proof.add_argument("--checkpoint", required=True)
    proof.add_argument("--summary", required=True)
    proof.add_argument("--reference", required=True)
    proof.add_argument("--claim", choices=["supports", "contradicts", "unknown"], default="supports")
    proof.add_argument("--actor", default="agent")
    proof.set_defaults(handler=evidence_command)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
