#!/usr/bin/env python3
"""Generate a lifecycle hook fragment; do not edit active agent configuration."""
import argparse
import json
import sys
from pathlib import Path
import shlex

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "bridge"))
from common import default_state_path, atomic_json
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--state", default=str(default_state_path()))
args = parser.parse_args()
state = Path(args.state).expanduser().resolve()
command = "python3 " + shlex.quote(str(root / "bridge/antigravity_hook.py")) + " --state " + shlex.quote(str(state))
hook = {}
for event in ["PreInvocation", "PostInvocation", "Stop"]:
    hook[event] = [{"type": "command", "command": command + " --event " + event, "timeout": 5}]
hook["PostToolUse"] = [{"matcher": "*", "hooks": [{"type": "command", "command": command + " --event PostToolUse", "timeout": 5}]}]
output = state.parent / "antigravity-hooks.json"
atomic_json(output, {"sneakpeek-observer": hook})
print(output)
