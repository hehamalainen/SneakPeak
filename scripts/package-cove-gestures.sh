#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_source="$task_root/runtime/cove-gestures-source"
task_scratch="$task_root/runtime/cove-gestures-build"
task_output="$task_root/output/cove-gestures"
task_app="$task_output/Cove Gestures.app"
python3 "$task_root/scripts/prepare-cove-source.py" --destination "$task_source"
"$task_source/scripts/build.sh" --scratch-path "$task_scratch" \
  --app "$task_app" --bundle-id local.sneakpeek.cove.gestures \
  --triple arm64-apple-macosx14.0
"$task_source/scripts/build.sh" --scratch-path "$task_scratch/intel" \
  --app "$task_scratch/intel/Cove Gestures.app" --bundle-id local.sneakpeek.cove.gestures \
  --triple x86_64-apple-macosx14.0
/usr/bin/lipo -create "$task_app/Contents/MacOS/SneakPeek" \
  "$task_scratch/intel/Cove Gestures.app/Contents/MacOS/SneakPeek" \
  -output "$task_scratch/CoveUniversal"
cp "$task_scratch/CoveUniversal" "$task_app/Contents/MacOS/SneakPeek"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
python3 "$task_root/scripts/preview-cove-gestures.py"
cp "$task_root/docs/cove-gestures-guide.txt" "$task_output/Start here.txt"
cp "$task_root/docs/cove-gesture-prompts.json" "$task_output/Artwork prompts.json"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$task_output" "$task_root/output/cove-gestures.zip"
/usr/bin/lipo -archs "$task_app/Contents/MacOS/SneakPeek"
print "Demo package: $task_output"
print "Shareable archive: $task_root/output/cove-gestures.zip"
