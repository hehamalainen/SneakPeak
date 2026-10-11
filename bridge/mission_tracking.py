"""Evidence-bound mission projections and a local, non-executable judgment queue.

No model calls or automatic policy changes. Taste is an explicit human signal,
never an inferred fact. The local file transport is not an identity boundary.
"""
from __future__ import annotations
from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import time
import uuid
from common import atomic_json


def identifier(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return None


def revision(mission):
    checks = [{"id": c["id"], "label": c["label"], "kind": c.get("kind") or "evidence",
               "required": c.get("required") is not False} for c in mission.get("checkpoints", [])]
    value = {"goal": mission.get("goal", ""), "constraints": mission.get("constraints") or [],
             "checks": sorted(checks, key=lambda c: c["id"])}
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def definition_revision(mission):
    value = {"id": mission["id"], "title": mission["title"], "goal": mission["goal"],
             "owner": mission.get("owner") or "You", "constraints": mission.get("constraints") or [],
             "pinned": bool(mission.get("pinned")), "evidenceMaxAgeSeconds": mission.get("evidenceMaxAgeSeconds", 86400)}
    value["checkpoints"] = [{"id": c["id"], "label": c["label"], "kind": c.get("kind") or "evidence",
                            "required": c.get("required") is not False, "maxAgeSeconds": c.get("maxAgeSeconds")} for c in mission.get("checkpoints", [])]
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def read_records(directory: Path, category: str):
    values, warnings = [], []
    for path in (directory / category).glob("*.json"):
        try:
            record = json.loads(path.read_text())
            if not isinstance(record, dict) or not identifier(record.get("id")):
                raise ValueError("Invalid record identifier")
            if not isinstance(record.get("missionId"), str) or not isinstance(record.get("goalRevision"), str):
                raise ValueError("A record needs mission and goal context")
            moment = record.get("observedAt") if category == "evidence" else record.get("createdAt")
            if not isinstance(moment, (int, float)) or not math.isfinite(moment) or moment < 0:
                raise ValueError("Invalid record timestamp")
            if category == "evidence" and (not isinstance(record.get("checkpointId"), str) or not isinstance(record.get("summary"), str)):
                raise ValueError("Invalid evidence record")
            if category == "evidence":
                for key in ["reference", "verdict", "actor", "source"]:
                    if not isinstance(record.get(key), str):
                        raise ValueError("Invalid evidence field")
                if record.get("digest") is not None and not isinstance(record["digest"], str):
                    raise ValueError("Invalid evidence digest")
                local = record.get("localFile")
                if local is not None and (not isinstance(local, dict) or not isinstance(local.get("size"), int) or not isinstance(local.get("modifiedNS"), str)):
                    raise ValueError("Invalid local artifact metadata")
            if category == "taste" and (record.get("valence") not in {"right", "off", "uncertain"} or record.get("impact") not in {"note", "review"}):
                raise ValueError("Invalid taste signal")
            if category == "taste" and not all(isinstance(record.get(k), str) for k in ["strength", "note", "acceptance"]):
                raise ValueError("Invalid taste detail")
            if category == "taste" and record.get("checkpointId") is not None and not isinstance(record["checkpointId"], str):
                raise ValueError("Invalid taste check reference")
            if category == "evidence-reviews" and (not isinstance(record.get("evidenceId"), str) or not isinstance(record.get("fingerprint"), str) or record.get("verdict") not in {"accept", "reject"}):
                raise ValueError("Invalid evidence review")
            if category == "judgments" and not all(isinstance(record.get(k), str) for k in ["title", "why", "impact"]):
                raise ValueError("Invalid judgment request")
            if category == "judgment-resolutions" and (not isinstance(record.get("judgmentId"), str) or record.get("outcome") not in {"keep", "change", "dismiss"}):
                raise ValueError("Invalid judgment resolution")
            values.append(record)
        except (OSError, ValueError, TypeError):
            warnings.append(f"A {category} record could not be read")
    return values, warnings


def save_record(directory: Path, category: str, record):
    key = identifier(record.get("id"))
    if key is None:
        raise ValueError("Record id must be a UUID")
    atomic_json(directory / category / (key + ".json"), record)


def reference_available(value):
    # A reference enables inspection. It is not fetched or treated as proof.
    return isinstance(value, str) and bool(value.strip()) and (
        value.startswith("/") or value.startswith("https://") or value.startswith("file:///"))


def fingerprint(record):
    local = record.get("localFile") or {}
    fields = [str(record.get(k) or "") for k in ["id", "missionId", "checkpointId", "goalRevision", "summary", "reference", "verdict"]]
    fields += [f'{float(record["observedAt"]):.6f}', str(record.get("digest") or ""),
               str(local.get("size", "")), str(local.get("modifiedNS", ""))]
    bound = "".join(str(len(s.encode())) + ":" + s for s in fields)
    return hashlib.sha256(bound.encode()).hexdigest()


def evidence_state(record, review, goal_revision, max_age, now, demo=False):
    if record.get("goalRevision") != goal_revision:
        return "goalChanged"
    observed = record.get("observedAt")
    if not isinstance(observed, (int, float)) or not math.isfinite(observed) or observed <= 0 or observed > now + 300:
        return "missingTime"
    if max_age and now - observed > max_age:
        return "stale"
    if not reference_available(record.get("reference")) and not (demo and str(record.get("reference", "")).startswith("demo://")):
        return "missingReference"
    local = record.get("localFile")
    if str(record.get("reference", "")).startswith("/"):
        try:
            stat = Path(record["reference"]).stat()
            if not Path(record["reference"]).is_file():
                return "missingArtifact"
            if not local:
                return "missingReference"
            if stat.st_size != local.get("size") or str(stat.st_mtime_ns) != local.get("modifiedNS"):
                return "artifactChanged"
        except OSError:
            return "missingArtifact"
    if (review and review.get("goalRevision") == goal_revision and review.get("evidenceId") == record["id"]
            and review.get("fingerprint") == fingerprint(record)
            and observed <= review.get("createdAt", 0) <= now + 300):
        return "accepted" if review.get("verdict") == "accept" else "rejected" if review.get("verdict") == "reject" else "reported"
    return "reported"


def queue_item(key, mission, kind, title, why, impact, priority, **extra):
    return {"id": key, "missionId": mission["id"], "missionTitle": mission["title"], "kind": kind,
            "title": title, "why": why, "impact": impact, "priority": priority, **extra}


def project(feed, directory: Path, now=None):
    """Rebuild a local projection; no transition from silence to verified success."""
    now = time.time() if now is None else now
    evidence, warnings = read_records(directory, "evidence")
    reviews, errors = read_records(directory, "evidence-reviews"); warnings.extend(errors)
    tastes, errors = read_records(directory, "taste"); warnings.extend(errors)
    judgments, errors = read_records(directory, "judgments"); warnings.extend(errors)
    resolutions, errors = read_records(directory, "judgment-resolutions"); warnings.extend(errors)
    review_by_id = {r.get("evidenceId"): r for r in sorted(reviews, key=lambda x: x.get("createdAt", 0))}
    resolved = {r.get("judgmentId"): r for r in sorted(resolutions, key=lambda x: x.get("createdAt", 0))}
    agents = feed.get("agents", [])
    workers_by_mission = defaultdict(list)
    for worker in agents:
        workers_by_mission[worker["missionId"]].append(worker)
    evidence_by_check = defaultdict(list)
    for record in evidence:
        evidence_by_check[(record["missionId"], record["checkpointId"])].append(record)
    tastes_by_mission = defaultdict(list)
    for note in tastes:
        tastes_by_mission[note["missionId"]].append(note)
    judgments_by_mission = defaultdict(list)
    for item in judgments:
        judgments_by_mission[item["missionId"]].append(item)
    queue = []
    for mission in feed.get("missions", []):
        queue_start = len(queue)
        mission["definitionRevision"] = definition_revision(mission)
        rev = revision(mission)
        mission["goalRevision"] = rev
        workers = workers_by_mission[mission["id"]]
        local_tastes = [dict(t) for t in tastes_by_mission[mission["id"]]]
        if feed.get("demo"):
            local_tastes += [dict(t) for t in mission.get("exampleTaste", [])]
        for note in local_tastes:
            note["contextStale"] = note.get("goalRevision") != rev
            resolution = resolved.get(note["id"])
            note["resolved"] = bool(resolution and resolution.get("goalRevision") == note.get("goalRevision"))
            note["resolution"] = resolution.get("outcome") if note["resolved"] else None
            if note.get("impact") == "review" and not note["resolved"]:
                queue.append(queue_item("taste:" + note["id"], mission, "taste", "Review your Taste signal", note.get("note") or "A human hunch needs a preference decision.",
                                        "Human judgment · no runtime permission will be granted", 1,
                                        recordId=note["id"], recordGoalRevision=note.get("goalRevision"), contextStale=note["contextStale"]))
        mission["tasteNotes"] = sorted(local_tastes, key=lambda t: t.get("createdAt", 0), reverse=True)
        verified = reported = missing = stale = conflicts = required = 0
        reasons = []
        for check in mission.get("checkpoints", []):
            is_required = check.get("required") is not False
            if is_required:
                required += 1
            kind = check.get("kind") or "evidence"
            check["kind"] = kind
            check["required"] = is_required
            records = [dict(e) for e in evidence_by_check[(mission["id"], check["id"])]]
            if feed.get("demo"):
                records += [dict(e) for e in check.get("exampleEvidence", [])]
            max_age = check.get("maxAgeSeconds", mission.get("evidenceMaxAgeSeconds", 86400))
            max_age = max_age if isinstance(max_age, (int, float)) and max_age >= 0 else 86400
            for record in records:
                review = review_by_id.get(record["id"])
                if feed.get("demo") and record.get("exampleReview") and review is None:
                    review = record["exampleReview"]
                record["state"] = evidence_state(record, review, rev, max_age, now, feed.get("demo", False))
                record["fingerprint"] = fingerprint(record)
                record["reviewedAt"] = review.get("createdAt") if review else None
            records.sort(key=lambda e: e.get("observedAt", 0), reverse=True)
            check["records"] = records
            if kind == "taste":
                judgments_for_check = [t for t in local_tastes if t.get("checkpointId") == check["id"] and not t["contextStale"] and t.get("acceptance") in {"accept", "reject"}]
                latest = max(judgments_for_check, key=lambda t: t.get("createdAt", 0)) if judgments_for_check else None
                state = "acceptedTaste" if latest and latest["acceptance"] == "accept" else "rejectedTaste" if latest else "missingTaste"
                check["trackingState"] = state
                check["status"] = "verified" if state == "acceptedTaste" else "rejected" if state == "rejectedTaste" else "pending"
                check["evidence"] = (latest.get("note") or "Human taste judgment") if latest else "Awaiting your taste judgment"
                check["source"] = "human taste"
            else:
                # A new record supersedes an older acceptance. Old passes cannot hide new failures.
                latest = records[0] if records else None
                state = latest["state"] if latest else "missing"
                if latest and state == "reported" and latest.get("verdict") == "contradicts":
                    state = "contradicted"
                elif latest and state == "reported" and latest.get("verdict") != "supports":
                    state = "inconclusive"
                check["trackingState"] = state
                check["status"] = "verified" if state == "accepted" else "rejected" if state in {"rejected", "contradicted"} else "reported" if state in {"reported", "inconclusive"} else "pending"
                if latest:
                    check["evidence"] = latest.get("summary", "Evidence record")
                    check["source"] = "human review" if state in {"accepted", "rejected"} else "agent report"
            if is_required:
                if state in {"accepted", "acceptedTaste"}: verified += 1
                elif state == "reported": reported += 1
                elif state in {"stale", "goalChanged", "artifactChanged"}: stale += 1
                elif state in {"rejected", "contradicted", "rejectedTaste"}: conflicts += 1
                else: missing += 1
            if state in {"rejected", "contradicted", "rejectedTaste"}:
                reasons.append(check["label"] + (": human taste rejected" if kind == "taste" else ": evidence contradicts or was rejected"))
        risks = [a for a in workers if a.get("trajectory") == "atRisk"]
        if risks:
            reasons.append(f"{len(risks)} agents reported a course risk")
        coverage = any(h.get("omittedLogs", 0) for h in feed.get("harnesses", []) if any(a.get("harnessId") == h["id"] for a in workers))
        if coverage:
            reasons.append("Monitoring coverage is incomplete")
        if conflicts or risks:
            course = "suspectedDrift"
            queue.append(queue_item("drift:" + mission["id"], mission, "drift", "Check the workflow's course", "; ".join(reasons),
                                    "Review the goal and supporting evidence before directing the work", 2))
        elif required and verified == required and not coverage:
            course = "readyForReview"
        elif verified or reported:
            course = "supportedProgress" if not coverage else "unknown"
        else:
            course = "unknown"
        if missing or stale or reported or coverage or not required:
            details = []
            if missing:
                details.append(f"{missing} required {'check needs' if missing == 1 else 'checks need'} usable evidence or Taste judgment")
            if stale:
                details.append(f"{stale} {'check has' if stale == 1 else 'checks have'} stale evidence")
            if reported:
                details.append(f"{reported} {'report awaits' if reported == 1 else 'reports await'} independent review")
            why = "; ".join(details) if required else "No required acceptance checks are defined"
            if coverage:
                why += "; monitoring coverage is incomplete"
            queue.append(queue_item("evidence:" + mission["id"], mission, "evidence", "Review the checkpoint evidence" if reported and not missing and not stale else "Evidence needs a checkpoint", why,
                                    "Outcome is unproven · this is a review item, not a permission request", 3))
        for a in workers:
            pending = a.get("request")
            if pending and now < pending.get("expiresAt", 0):
                queue.append(queue_item("runtime:" + a["id"] + ":" + pending["id"], mission, "runtime", pending["title"], pending["detail"],
                                        "Connected host decision" if pending.get("mode") == "decision" else "Answer at the source session", 0,
                                        agentId=a["id"], requestId=pending["id"]))
            elif a.get("status") == "attention":
                queue.append(queue_item("source:" + a["id"], mission, "sourceIssue", "Inspect a source interruption",
                                        a.get("summary", "An agent stopped without a decision payload"),
                                        "Inspect the original session · no executable decision is available", 2, agentId=a["id"]))
        for judgment in judgments_by_mission[mission["id"]]:
            resolution = resolved.get(judgment["id"])
            if resolution and resolution.get("goalRevision") == judgment.get("goalRevision"):
                continue
            queue.append(queue_item("judgment:" + judgment["id"], mission, "judgment", judgment.get("title", "A human decision is needed"),
                                    judgment.get("why", ""), judgment.get("impact", "Record guidance, then steer the source workflow"), 1,
                                    recordId=judgment["id"], recordGoalRevision=judgment.get("goalRevision"), contextStale=judgment.get("goalRevision") != rev))
        decision_count = sum(q["kind"] in {"runtime", "taste", "judgment"} for q in queue[queue_start:])
        mission["assessment"] = {"goalRevision": rev, "course": course,
                                 "evidence": "conflicting" if conflicts else "missing" if missing or not required else "stale" if stale else "verified" if verified == required and required else "reported",
                                 "requiredCount": required, "verifiedCount": verified, "reportedCount": reported,
                                 "missingCount": missing, "staleCount": stale, "conflictCount": conflicts,
                                 "decisionCount": decision_count, "coverageIncomplete": bool(coverage), "reasons": reasons}
    feed["queue"] = sorted(queue, key=lambda q: (q["priority"], q["missionTitle"], q["id"]))
    feed.setdefault("warnings", []).extend(warnings)
    return feed


def add_evidence(directory, mission, checkpoint_id, summary, reference, verdict="supports", actor="agent"):
    if checkpoint_id not in {c["id"] for c in mission["checkpoints"]}:
        raise ValueError("Checkpoint not found")
    if verdict not in {"supports", "contradicts", "unknown"} or not summary.strip():
        raise ValueError("Provide an evidence summary and a valid claim")
    value = {"id": str(uuid.uuid4()), "missionId": mission["id"], "checkpointId": checkpoint_id,
             "goalRevision": revision(mission), "summary": summary[:10000], "reference": reference[:2048],
             "verdict": verdict, "actor": actor, "source": "report", "observedAt": time.time(), "digest": None}
    if reference.startswith("/"):
        path = Path(reference)
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
            value["digest"] = digest.hexdigest()
            stat = path.stat()
            value["localFile"] = {"size": stat.st_size, "modifiedNS": str(stat.st_mtime_ns)}
    save_record(directory, "evidence", value)
    return value
