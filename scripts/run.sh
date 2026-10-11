#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
if [[ ! -x "$task_root/dist/SneakPeek.app/Contents/MacOS/SneakPeek" ]]; then
  "$task_root/scripts/build.sh"
fi
open -n "$task_root/dist/SneakPeek.app" --args "$@" --state "$task_root/runtime/state.json"
