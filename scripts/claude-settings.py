#!/usr/bin/env python3
"""Generate an opt-in settings file. Does not edit any Claude configuration."""
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
parser.add_argument("--trusted-local-inline", action="store_true", help="Enable unsigned local replies only when all state writers are trusted")
args = parser.parse_args()
state = Path(args.state).expanduser().resolve()
command = "python3 " + shlex.quote(str(root / "bridge/claude_hook.py")) + " --state " + shlex.quote(str(state))
if args.trusted_local_inline:
    command += " --trusted-local-inline"
settings = {"hooks": {"PermissionRequest": [{"matcher": "*", "hooks": [{"type": "command", "command": command, "timeout": 130}]}]}}
output = state.parent / "claude-settings.json"
atomic_json(output, settings)
print(output)
