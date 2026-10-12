#!/usr/bin/env python3
"""Configure opt-in observer hooks in one explicitly selected project."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shlex
import shutil
import sys
from common import atomic_json, default_state_path


def configure(provider: str, project: Path, state: Path):
    project = project.resolve()
    if not project.is_dir():
        raise ValueError("Choose an existing project folder")
    bridge = Path(__file__).resolve().parent
    if provider == "antigravity":
        target = project / ".agents/hooks.json"
        command = "python3 " + shlex.quote(str(bridge / "antigravity_hook.py")) + " --state " + shlex.quote(str(state.resolve()))
        definition = {event: [{"type": "command", "command": command + " --event " + event, "timeout": 5}]
                      for event in ["PreInvocation", "PostInvocation", "Stop"]}
        definition["PostToolUse"] = [{"matcher": "*", "hooks": [{"type": "command", "command": command + " --event PostToolUse", "timeout": 5}]}]
        addition = {"sneakpeek-observer": definition}
    elif provider == "copilot":
        target = project / ".github/hooks/sneakpeek.json"
        hooks = {event: [{"type": "command", "exec": "python3",
                          "args": [str(bridge / "copilot_hook.py"), "--state", str(state.resolve()), "--event", event], "timeoutSec": 5}]
                 for event in ["sessionStart", "userPromptSubmitted", "agentStop", "postToolUseFailure", "errorOccurred"]}
        addition = {"version": 1, "hooks": hooks}
    else:
        raise ValueError("Observer hook setup is available for Antigravity and Copilot")
    if target.is_symlink() or not target.parent.resolve().is_relative_to(project):
        raise ValueError("Hook configuration must be a regular file inside the selected project")
    previous = None
    if target.exists():
        previous = json.loads(target.read_text())
        if not isinstance(previous, dict):
            raise ValueError("Existing hook configuration must be a JSON object")
    if provider == "antigravity":
        merged = dict(previous or {})
        merged.update(addition)  # Preserve every other named hook.
    else:
        # This file belongs to SneakPeek; other .github/hooks/*.json files stay separate.
        merged = addition
        if previous and set(previous) - {"version", "hooks"}:
            raise ValueError("The SneakPeek hook file contains unrelated settings; use another file")
        if previous:
            previous_hooks = previous.get("hooks", {})
            if not isinstance(previous_hooks, dict):
                raise ValueError("Existing hooks must be a JSON object")
            for event, handlers in previous_hooks.items():
                if not isinstance(handlers, list):
                    raise ValueError("Existing hook handlers must be a list")
                if any(not isinstance(h, dict) for h in handlers):
                    raise ValueError("Each existing hook handler must be a JSON object")
                if any(not isinstance(h.get("args", []), list) or
                       any(not isinstance(arg, str) for arg in h.get("args", [])) for h in handlers):
                    raise ValueError("Existing hook args must be a list of strings")
                unrelated = [h for h in handlers if not any(arg.endswith("/copilot_hook.py") for arg in h.get("args", []))]
                merged["hooks"][event] = unrelated + merged["hooks"].get(event, [])
    target.parent.mkdir(parents=True, exist_ok=True)
    backup = target.with_suffix(target.suffix + ".before-sneakpeek")
    if target.exists() and not backup.exists():
        shutil.copy2(target, backup)
    atomic_json(target, merged)
    return {"provider": provider, "project": str(project), "path": str(target),
            "message": "Observer hooks configured. Start or resume a session in this project."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=["antigravity", "copilot"], required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--state", default=str(default_state_path()))
    args = parser.parse_args()
    try:
        print(json.dumps(configure(args.provider, Path(args.project), Path(args.state))))
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
