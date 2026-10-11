#!/usr/bin/env python3
"""Explicit human actions for mission evidence, Taste, and local judgment records."""
from __future__ import annotations
import argparse
import copy
import fcntl
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid
from common import atomic_json
from mission_tracking import add_evidence, definition_revision, evidence_state, fingerprint, read_records, revision, save_record
from peek import mission_filename


def context(state, payload):
    feed = json.loads(state.read_text())
    mid = payload.get("missionId")
    mission = next((copy.deepcopy(m) for m in feed.get("missions", []) if m["id"] == mid), None)
    if mission is None:
        raise ValueError("This mission is no longer available")
    definition = state.parent / "missions" / mission_filename(mid)
    if definition.exists():
        latest = json.loads(definition.read_text())
        if latest.get("id") == mid:
            # Keep current records for inspection, but use the latest human goal and checks.
            for key in ["goal", "constraints", "checkpoints", "evidenceMaxAgeSeconds", "workspace", "goalOrigin"]:
                if key in latest:
                    mission[key] = latest[key]
    return feed, mission


def pin_mission(directory, mission):
    folder = directory / "missions"
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / mission_filename(mission["id"])
    with target.with_suffix(".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if target.exists():
            latest = json.loads(target.read_text())
            if revision(latest) != revision(mission):
                raise ValueError("The goal changed while this record was being prepared.")
            return
        definition = {k: mission[k] for k in ["id", "title", "goal", "owner", "constraints", "evidenceMaxAgeSeconds", "workspace", "goalOrigin"] if k in mission}
        definition["checkpoints"] = [{k: c[k] for k in ["id", "label", "kind", "required", "maxAgeSeconds", "status", "evidence", "source"] if k in c} for c in mission["checkpoints"]]
        definition["pinned"] = True
        atomic_json(target, definition)


def apply(state: Path, action: str, payload: dict):
    feed, mission = context(state, payload)
    directory = state.parent
    rev = revision(mission)
    if action == "definition":
        folder = directory / "missions"
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / mission_filename(mission["id"])
        with target.with_suffix(".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = json.loads(target.read_text()) if target.exists() else mission
            if definition_revision(current) != payload.get("definitionRevision"):
                raise ValueError("This mission changed while the editor was open. Refresh before saving.")
            definition = payload.get("definition")
            if not isinstance(definition, dict) or definition.get("id") != mission["id"]:
                raise ValueError("Invalid mission definition")
            if not all(isinstance(definition.get(k), str) and definition[k].strip() for k in ["title", "goal"]):
                raise ValueError("Mission title and outcome are required")
            checks = definition.get("checkpoints", [])
            if not isinstance(checks, list) or any(not isinstance(c, dict) or not isinstance(c.get("id"), str) or not isinstance(c.get("label"), str) or not c["label"].strip() for c in checks):
                raise ValueError("Each check needs an identity and a nonempty label")
            if len({c["id"] for c in checks}) != len(checks):
                raise ValueError("Acceptance check identities must be unique")
            for key in ["assessment", "tasteNotes", "goalRevision", "definitionRevision"]:
                definition.pop(key, None)
            for check in checks:
                for key in ["records", "trackingState", "exampleEvidence"]:
                    check.pop(key, None)
                current_check = next((c for c in current.get("checkpoints", []) if c["id"] == check["id"]), None)
                if current_check:
                    for key in ["status", "evidence", "source"]:
                        if key in current_check:
                            check[key] = current_check[key]
            if definition["goal"] != current["goal"]:
                definition["goalOrigin"] = "local-edit"
            elif "goalOrigin" in current:
                definition["goalOrigin"] = current["goalOrigin"]
            atomic_json(target, definition)
        return {"id": mission["id"]}
    if action != "resolve" and payload.get("goalRevision") != rev:
        raise ValueError("The goal changed. Refresh the mission before recording this action.")
    now = time.time()
    if action == "evidence":
        if not feed.get("demo"):
            pin_mission(directory, mission)
        return add_evidence(directory, mission, payload.get("checkpointId"), str(payload.get("summary", "")),
                            str(payload.get("reference", "")), payload.get("verdict", "supports"), "manual report")
    if action == "review-evidence":
        records, _ = read_records(directory, "evidence")
        record = next((e for e in records if e["id"] == payload.get("evidenceId") and e["missionId"] == mission["id"]), None)
        if record is None and feed.get("demo"):
            source_mission = next(m for m in feed["missions"] if m["id"] == mission["id"])
            record = next((e for c in source_mission["checkpoints"] for e in c.get("records", []) if e["id"] == payload.get("evidenceId")), None)
        if record is None or fingerprint(record) != payload.get("fingerprint"):
            raise ValueError("The evidence record changed or is no longer available.")
        check = next((c for c in mission["checkpoints"] if c["id"] == record["checkpointId"]), None)
        max_age = check.get("maxAgeSeconds", mission.get("evidenceMaxAgeSeconds", 86400)) if check else 86400
        if evidence_state(record, None, rev, max_age, now, feed.get("demo", False)) != "reported":
            raise ValueError("The evidence is stale, unavailable, or belongs to an earlier goal.")
        if record.get("digest") and str(record.get("reference", "")).startswith("/"):
            digest = hashlib.sha256()
            with Path(record["reference"]).open("rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
            if digest.hexdigest() != record["digest"]:
                raise ValueError("The artifact content changed. Attach a new evidence record before reviewing.")
        if payload.get("verdict") not in {"accept", "reject"}:
            raise ValueError("Choose whether this evidence satisfies the check.")
        result = {"id": str(uuid.uuid4()), "missionId": mission["id"], "goalRevision": rev,
                  "evidenceId": record["id"], "fingerprint": fingerprint(record), "verdict": payload["verdict"],
                  "createdAt": now, "source": "human review", "note": str(payload.get("note", ""))[:10000]}
        if not feed.get("demo"):
            pin_mission(directory, mission)
        save_record(directory, "evidence-reviews", result)
        return result
    if action == "taste":
        if payload.get("valence") not in {"right", "off", "uncertain"} or payload.get("impact", "note") not in {"note", "review"}:
            raise ValueError("Choose a Taste signal and its review intent.")
        checkpoint_id = payload.get("checkpointId") or None
        acceptance = payload.get("acceptance", "unassessed")
        if acceptance not in {"unassessed", "accept", "reject"}:
            raise ValueError("Invalid taste judgment")
        check = next((c for c in mission["checkpoints"] if c["id"] == checkpoint_id), None)
        if acceptance != "unassessed" and (check is None or check.get("kind") != "taste"):
            raise ValueError("Taste can satisfy only a check explicitly defined as human taste.")
        result = {"id": str(uuid.uuid4()), "missionId": mission["id"], "goalRevision": rev,
                  "checkpointId": checkpoint_id, "valence": payload["valence"],
                  "strength": "conviction" if payload.get("strength") == "conviction" else "hunch",
                  "note": str(payload.get("note", ""))[:10000], "impact": payload.get("impact", "note"),
                  "acceptance": acceptance, "source": "human", "createdAt": now}
        if not feed.get("demo"):
            pin_mission(directory, mission)
        save_record(directory, "taste", result)
        return result
    if action == "judgment":
        title = str(payload.get("title", "")).strip()
        if not title:
            raise ValueError("Describe the decision that needs a person.")
        result = {"id": str(uuid.uuid4()), "missionId": mission["id"], "goalRevision": rev,
                  "title": title[:300], "why": str(payload.get("why", ""))[:10000],
                  "impact": str(payload.get("impact", ""))[:2000], "source": "human request", "createdAt": now}
        if not feed.get("demo"):
            pin_mission(directory, mission)
        save_record(directory, "judgments", result)
        return result
    if action == "resolve":
        tastes, _ = read_records(directory, "taste")
        judgments, _ = read_records(directory, "judgments")
        candidates = tastes + judgments
        if feed.get("demo"):
            candidates += [t for m in feed["missions"] for t in m.get("tasteNotes", [])]
        record = next((r for r in candidates if r["id"] == payload.get("recordId") and r["missionId"] == mission["id"]), None)
        if record is None or record.get("goalRevision") != payload.get("recordGoalRevision"):
            raise ValueError("That judgment request changed or is no longer available.")
        if payload.get("outcome") not in {"keep", "change", "dismiss"}:
            raise ValueError("Choose a judgment outcome")
        if record.get("goalRevision") != rev and payload["outcome"] != "dismiss":
            raise ValueError("This request refers to an earlier goal. Dismiss it or create a new request.")
        result = {"id": str(uuid.uuid4()), "missionId": mission["id"], "goalRevision": record["goalRevision"],
                  "judgmentId": record["id"], "outcome": payload["outcome"], "note": str(payload.get("note", ""))[:10000],
                  "source": "human decision", "createdAt": now}
        save_record(directory, "judgment-resolutions", result)
        return result
    raise ValueError("Unsupported mission action")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True)
    parser.add_argument("--action", required=True, choices=["definition", "evidence", "review-evidence", "taste", "judgment", "resolve"])
    args = parser.parse_args()
    try:
        result = apply(Path(args.state).resolve(), args.action, json.load(sys.stdin))
        print(json.dumps({"ok": True, "id": result["id"]}))
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
