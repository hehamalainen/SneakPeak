#!/usr/bin/env python3
"""Generate an opt-in settings file. Does not edit any Claude configuration."""
import json
from pathlib import Path
import shlex

root = Path(__file__).resolve().parent.parent
command = "python3 " + shlex.quote(str(root / "bridge/claude_hook.py")) + " --state " + shlex.quote(str(root / "runtime/state.json"))
settings = {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": command, "timeout": 130}]}]}}
output = root / "runtime/claude-settings.json"
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps(settings, indent=2))
print(output)
