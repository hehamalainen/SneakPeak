"""Data-only harness registry. Adding a source never imports or runs adapter code."""
from __future__ import annotations
import glob
import json
from pathlib import Path
import re
import time
from common import atomic_json

BUILTINS = [
    {"id": "codex", "name": "Codex", "format": "codex", "logs": ["~/.codex/sessions/**/*.jsonl"]},
    {"id": "claude", "name": "Claude Code", "provider": "Claude", "format": "claude", "logs": ["~/.claude/projects/**/*.jsonl"]},
    {"id": "antigravity", "name": "Antigravity", "format": "antigravity", "logs": [
        "~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl",
        "~/.gemini/antigravity-ide/brain/*/.system_generated/logs/transcript.jsonl",
        "~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl"]},
    {"id": "copilot", "name": "GitHub Copilot", "format": "copilot", "logs": ["~/.copilot/session-state/*/events.jsonl"]},
]
FORMATS = {"codex", "claude", "antigravity", "copilot", "sneakpeek"}
DISCOVERY_LIMIT = 100


def load_settings(directory: Path):
    try:
        value = json.loads((directory / "harnesses.json").read_text())
        if not isinstance(value, dict):
            raise ValueError("Expected an object")
        return value, []
    except FileNotFoundError:
        return {}, []
    except (OSError, ValueError):
        return {}, ["Harness settings could not be read; default sources are being used"]


class Registry:
    def __init__(self, home: Path, directory: Path):
        self.home, self.directory = home, directory
        self.definitions = []
        self.recent_hours = 24
        self.warnings = []
        self.reload()

    def reload(self):
        settings, self.warnings = load_settings(self.directory)
        hours = settings.get("recentHours", 24)
        self.recent_hours = min(720, max(1, hours)) if isinstance(hours, (float, int)) else 24
        raw = settings.get("harnesses", [])
        overrides = {}
        for value in raw if isinstance(raw, list) else []:
            if not isinstance(value, dict) or not isinstance(value.get("id"), str):
                self.warnings.append("A harness entry has an invalid identifier")
                continue
            overrides[value["id"]] = value
        definitions = []
        for base in BUILTINS:
            value = dict(base)
            # Builtin identities and parsers are fixed; roots and enabled state are configurable.
            override = overrides.pop(base["id"], {})
            value["enabled"] = override.get("enabled", True) is not False
            if isinstance(override.get("logs"), list) and override["logs"]:
                value["logs"] = override["logs"]
            value["provider"] = base.get("provider", base["name"])
            value["builtin"] = True
            definitions.append(value)
        for hid, value in overrides.items():
            if not isinstance(hid, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", hid):
                self.warnings.append("An additional harness has an invalid identifier")
                continue
            name, logs = value.get("name"), value.get("logs")
            if not isinstance(name, str) or not name.strip() or not isinstance(logs, list) or not logs:
                self.warnings.append("An additional harness needs a name and event log")
                continue
            if not isinstance(value.get("format", "sneakpeek"), str) or value.get("format", "sneakpeek") not in FORMATS:
                self.warnings.append("An additional harness has an unsupported event format")
                continue
            definitions.append({"id": hid, "name": name.strip()[:64], "provider": name.strip()[:64],
                                "logs": logs, "format": value.get("format", "sneakpeek"),
                                "enabled": value.get("enabled", True) is not False, "builtin": False})
        self.definitions = definitions

    def expand(self, path: str) -> str:
        if path.startswith("~/"):
            return str(self.home / path[2:])
        return path

    def pattern_error(self, pattern):
        if not isinstance(pattern, str) or not pattern or len(pattern) > 4096 or "\0" in pattern:
            return "Event log path is invalid"
        expanded = self.expand(pattern)
        if not Path(expanded).is_absolute():
            return "Use an absolute event log path"
        if glob.has_magic(expanded):
            prefix = re.split(r"[*?\[]", expanded, maxsplit=1)[0]
            try:
                literal = Path(prefix) if prefix.endswith("/") else Path(prefix).parent
                try:
                    anchor = literal.resolve(strict=True)
                except FileNotFoundError:
                    anchor = literal.resolve()  # A source may not have created its log folder yet.
                roots = (self.home.resolve(), self.directory.resolve())
            except (OSError, RuntimeError, ValueError):
                return "Event log folder could not be resolved"
            if not any(anchor != parent and anchor.is_relative_to(parent) for parent in roots):
                return "Wildcard scans need a specific folder below home or the state directory"
        return None

    def discover(self, definition: dict):
        files, detected, errors = set(), False, []
        patterns = definition["logs"] if definition["enabled"] else []
        if len(patterns) > 16:
            errors.append("At most 16 event log paths may be configured")
            patterns = []
        for pattern in patterns:
            error = self.pattern_error(pattern)
            if error:
                errors.append(error)
                continue
            expanded = self.expand(pattern)
            anchor = re.split(r"[*?\[]", expanded, maxsplit=1)[0]
            anchor_path = Path(anchor) if anchor.endswith("/") else Path(anchor).parent
            detected = detected or anchor_path.exists()
            try:
                for candidate in glob.iglob(expanded, recursive="**" in expanded):
                    path = Path(candidate)
                    if path.is_file():
                        files.add(path)
            except OSError:
                errors.append("An event log folder could not be read")
        stamped = []
        for path in files:
            try:
                stamped.append((path.stat().st_mtime, path))
            except OSError:
                continue  # A harness may rotate or delete logs during discovery.
        stamped.sort(reverse=True)
        eligible = [p for modified, p in stamped if time.time() - modified < self.recent_hours * 3600]
        recent = eligible[:DISCOVERY_LIMIT]
        omitted = max(0, len(eligible) - len(recent)) if definition["enabled"] else 0
        last_seen = stamped[0][0] if stamped else None
        enabled = definition["enabled"]
        status = "disabled" if not enabled else "error" if errors else "ready" if recent else "waiting" if detected else "missing"
        detail = ("Observation is switched off" if not enabled else "; ".join(errors) if errors else
                  f"{len(recent)} recent event logs · observation ready" if recent else
                  f"No logs updated in the last {int(self.recent_hours)} hours. Start or resume a session." if detected else
                  "Waiting for this harness to create its local event log")
        if omitted:
            detail += f" · {omitted} recent logs omitted (limit {DISCOVERY_LIMIT}); coverage is incomplete"
        catalog = {"id": definition["id"], "name": definition["name"], "provider": definition["provider"],
                   "format": definition["format"], "enabled": enabled, "builtin": definition["builtin"],
                   "logs": definition["logs"], "status": status, "detail": detail,
                   "lastSeen": last_seen, "recentLogs": len(recent), "sessionCount": 0,
                   "discoveryLimit": DISCOVERY_LIMIT, "omittedLogs": omitted}
        return recent if enabled else [], catalog


def register(directory: Path, name: str, events: str | None = None, event_format: str = "sneakpeek"):
    if not name.strip() or event_format not in FORMATS:
        raise ValueError("Provide a harness name and supported format")
    hid = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")[:64]
    if not hid or hid in {x["id"] for x in BUILTINS}:
        raise ValueError("Choose a name different from the built-in harness identifiers")
    settings, warnings = load_settings(directory)
    if warnings:
        raise ValueError(warnings[0])
    logs = events or str(directory.resolve() / "custom" / hid / "events.jsonl")
    log = Path(logs).expanduser()
    if not log.is_absolute() or glob.has_magic(str(log)):
        raise ValueError("Choose one absolute event log file, without wildcard patterns")
    entries = settings.setdefault("harnesses", [])
    if not isinstance(entries, list) or any(not isinstance(x, dict) for x in entries):
        raise ValueError("Harness settings must contain a list of JSON objects")
    if any(x.get("id") == hid for x in entries):
        raise ValueError("A harness with this name is already registered")
    entries.append({"id": hid, "name": name.strip()[:64], "format": event_format, "logs": [str(log)], "enabled": True})
    atomic_json(directory / "harnesses.json", settings)
    return entries[-1]
