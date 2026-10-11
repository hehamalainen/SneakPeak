"""Reject malformed transport records before they can poison a whole feed."""
import math


def number(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def mission(value):
    if not isinstance(value, dict) or not all(isinstance(value.get(k), str) for k in ("id", "title", "goal")):
        raise ValueError("Invalid mission")
    if value.get("goalOrigin") is not None and not isinstance(value["goalOrigin"], str):
        raise ValueError("Invalid goal origin")
    checks = value.get("checkpoints")
    if value.get("definitionRevision") is not None and (not isinstance(value["definitionRevision"], int) or isinstance(value["definitionRevision"], bool) or not 0 <= value["definitionRevision"] < 2**63):
        raise ValueError("Invalid definition revision")
    if not isinstance(checks, list):
        raise ValueError("Invalid checkpoints")
    ids = set()
    for check in checks:
        if not isinstance(check, dict) or not all(isinstance(check.get(k), str) for k in ("id", "label", "status", "evidence", "source")):
            raise ValueError("Invalid checkpoint")
        if check["id"] in ids:
            raise ValueError("Duplicate checkpoint identity")
        ids.add(check["id"])
    return dict(value)


def agent(value):
    if not isinstance(value, dict) or not all(isinstance(value.get(k), str) for k in
            ("id", "missionId", "name", "provider", "status", "summary", "evidence", "trajectory", "nextStep")):
        raise ValueError("Invalid agent")
    if not all(number(value.get(k)) for k in ("lastActivity", "lastProgress")):
        raise ValueError("Invalid agent timestamp")
    for key in ("sessionId", "sourceApp", "artifactPath", "harnessId", "handoffKind", "workspace", "provenance", "progressFreshness", "reportedTrajectory"):
        if value.get(key) is not None and not isinstance(value[key], str):
            raise ValueError("Invalid agent metadata")
    pending = value.get("request")
    if pending is not None:
        if not isinstance(pending, dict) or not all(isinstance(pending.get(k), str) for k in ("id", "title", "detail", "mode")):
            raise ValueError("Invalid request")
        if pending.get("transport") is not None and not isinstance(pending["transport"], str):
            raise ValueError("Invalid request transport")
        if not number(pending.get("expiresAt")) or not isinstance(pending.get("choices"), list):
            raise ValueError("Invalid request lifetime or choices")
        for choice in pending["choices"]:
            if not isinstance(choice, dict) or not all(isinstance(choice.get(k), str) for k in ("id", "label")):
                raise ValueError("Invalid request choice")
    return dict(value)
