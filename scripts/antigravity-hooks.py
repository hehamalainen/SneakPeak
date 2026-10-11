#!/usr/bin/env python3
"""Generate a lifecycle hook fragment; do not edit active agent configuration."""
import json
from pathlib import Path
import shlex

root = Path(__file__).resolve().parent.parent
command = "python3 " + shlex.quote(str(root / "bridge/antigravity_hook.py")) + " --state " + shlex.quote(str(root / "runtime/state.json"))
hook = {}
for event in ["PreInvocation", "PostInvocation", "Stop"]:
    hook[event] = [{"type": "command", "command": command + " --event " + event, "timeout": 5}]
hook["PostToolUse"] = [{"matcher": "*", "hooks": [{"type": "command", "command": command + " --event PostToolUse", "timeout": 5}]}]
output = root / "runtime/antigravity-hooks.json"
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps({"sneakpeek-observer": hook}, indent=2))
print(output)
