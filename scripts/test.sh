#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
mkdir -p .build/cache
export CLANG_MODULE_CACHE_PATH="$task_root/.build/cache"
python3 -m unittest discover -s Tests -v
# Some Command Line Tools releases package Testing as a framework outside
# SwiftPM's default search paths. Use the active toolchain's own framework.
task_swift="$(xcrun --find swift)"
task_developer_root="${task_swift:h:h:h}"
task_frameworks="$task_developer_root/Library/Developer/Frameworks"
task_interop="$task_developer_root/Library/Developer/usr/lib"
if [[ -d "$task_frameworks/Testing.framework" ]]; then
  swift test -Xswiftc -F -Xswiftc "$task_frameworks" \
    -Xlinker -rpath -Xlinker "$task_frameworks" \
    -Xlinker -rpath -Xlinker "$task_interop"
else
  swift test
fi
