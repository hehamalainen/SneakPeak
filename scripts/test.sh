#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
task_scratch="$task_root/.build"
if (( $# )); then
  if [[ "$1" != "--scratch-path" || $# != 2 ]]; then
    print -u2 "Usage: scripts/test.sh [--scratch-path /absolute/path]"; exit 2
  fi
  task_scratch="$2"
fi
mkdir -p "$task_scratch/cache"
export CLANG_MODULE_CACHE_PATH="$task_scratch/cache"
python3 -m unittest discover -s Tests -v
# Some Command Line Tools releases package Testing as a framework outside
# SwiftPM's default search paths. Use the active toolchain's own framework.
task_swift="$(xcrun --find swift)"
task_developer_root="${task_swift:h:h:h}"
task_frameworks="$task_developer_root/Library/Developer/Frameworks"
task_interop="$task_developer_root/Library/Developer/usr/lib"
if [[ -d "$task_frameworks/Testing.framework" ]]; then
  swift test --scratch-path "$task_scratch" -Xswiftc -F -Xswiftc "$task_frameworks" \
    -Xlinker -rpath -Xlinker "$task_frameworks" \
    -Xlinker -rpath -Xlinker "$task_interop"
else
  swift test --scratch-path "$task_scratch"
fi
