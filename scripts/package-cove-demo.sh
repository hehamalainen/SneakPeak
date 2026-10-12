#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_source="$task_root/runtime/cove-demo-source"
task_scratch="$task_root/runtime/cove-demo-build"
task_output="$task_root/output/cove-demo"
task_app="$task_output/Cove Demo.app"
mkdir -p "$task_output/Gesture recordings" "$task_scratch"
python3 "$task_root/scripts/prepare-cove-source.py" --destination "$task_source"
"$task_source/scripts/build.sh" --scratch-path "$task_scratch/arm64" \
  --app "$task_app" --bundle-id local.sneakpeek.cove.demo \
  --triple arm64-apple-macosx14.0
"$task_source/scripts/build.sh" --scratch-path "$task_scratch/intel" \
  --app "$task_scratch/intel/Cove Demo.app" --bundle-id local.sneakpeek.cove.demo \
  --triple x86_64-apple-macosx14.0
/usr/bin/lipo -create "$task_app/Contents/MacOS/SneakPeek" \
  "$task_scratch/intel/Cove Demo.app/Contents/MacOS/SneakPeek" \
  -output "$task_scratch/CoveUniversal"
cp "$task_scratch/CoveUniversal" "$task_app/Contents/MacOS/SneakPeek"
codesign --force --sign - "$task_app"
codesign --verify --deep --strict "$task_app"
cp "$task_root/docs/cove-demo-guide.txt" "$task_output/Start here.txt"
COVE_PREVIEW_APP="$task_app/Contents/MacOS/SneakPeek" python3 "$task_root/scripts/preview-cove.py"
for task_gesture in paw-up settle withdraw holding-paws drift rejoin; do
  cp "$task_root/output/cove-animation-assets/$task_gesture.gif" "$task_output/Gesture recordings/"
done
if [[ -f "$task_root/output/cove-character-refinement/cove-simplification-review.pdf" ]]; then
  cp "$task_root/output/cove-character-refinement/cove-simplification-review.pdf" "$task_output/Cove design review.pdf"
fi
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$task_output" "$task_root/output/cove-demo.zip"
/usr/bin/lipo -archs "$task_app/Contents/MacOS/SneakPeek"
print "Demo package: $task_output"
print "Shareable archive: $task_root/output/cove-demo.zip"
