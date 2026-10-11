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
    checks = value.get("checkpoints")
    token = value.get("definitionRevision")
    if token is not None:
        hash_revision = isinstance(token, str) and len(token) == 64 and all(c in '0123456789abcdef' for c in token)
        legacy_revision = isinstance(token, int) and not isinstance(token, bool) and 0 <= token < 2**63
        if not hash_revision and not legacy_revision:
            raise ValueError("Invalid definition revision")
    for key in ("owner", "workspace", "goalRevision"):
        if value.get(key) is not None and not isinstance(value[key], str):
            raise ValueError("Invalid mission context")
    if value.get("constraints") is not None and (not isinstance(value["constraints"], list) or not all(isinstance(c, str) for c in value["constraints"])):
        raise ValueError("Invalid mission constraints")
    if value.get("pinned") is not None and not isinstance(value["pinned"], bool):
        raise ValueError("Invalid mission persistence setting")
    if value.get("evidenceMaxAgeSeconds") is not None and (not number(value["evidenceMaxAgeSeconds"]) or value["evidenceMaxAgeSeconds"] < 0):
        raise ValueError("Invalid evidence age window")
    if not isinstance(checks, list):
        raise ValueError("Invalid checkpoints")
    ids = set()
    for check in checks:
        if not isinstance(check, dict) or not all(isinstance(check.get(k), str) for k in ("id", "label", "status", "evidence", "source")):
            raise ValueError("Invalid checkpoint")
        if check["id"] in ids:
            raise ValueError("Duplicate checkpoint identity")
        if check.get("kind") is not None and check["kind"] not in ("evidence", "taste"):
            raise ValueError("Invalid checkpoint origin")
        if check.get("required") is not None and not isinstance(check["required"], bool):
            raise ValueError("Invalid checkpoint requirement")
        if check.get("maxAgeSeconds") is not None and (not number(check["maxAgeSeconds"]) or check["maxAgeSeconds"] < 0):
            raise ValueError("Invalid checkpoint age window")
        ids.add(check["id"])
    return dict(value)


def agent(value):
    if not isinstance(value, dict) or not all(isinstance(value.get(k), str) for k in
            ("id", "missionId", "name", "provider", "status", "summary", "evidence", "trajectory", "nextStep")):
        raise ValueError("Invalid agent")
    if not all(number(value.get(k)) for k in ("lastActivity", "lastProgress")):
        raise ValueError("Invalid agent timestamp")
    for key in ("sessionId", "sourceApp", "artifactPath", "harnessId", "handoffKind", "workspace"):
        if value.get(key) is not None and not isinstance(value[key], str):
            raise ValueError("Invalid agent metadata")
    pending = value.get("request")
    if pending is not None:
        if not isinstance(pending, dict) or not all(isinstance(pending.get(k), str) for k in ("id", "title", "detail", "mode")):
            raise ValueError("Invalid request")
        if not number(pending.get("expiresAt")) or not isinstance(pending.get("choices"), list):
            raise ValueError("Invalid request lifetime or choices")
        for choice in pending["choices"]:
            if not isinstance(choice, dict) or not all(isinstance(choice.get(k), str) for k in ("id", "label")):
                raise ValueError("Invalid request choice")
    return dict(value)
