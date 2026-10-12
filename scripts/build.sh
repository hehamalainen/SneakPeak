#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
task_app="$task_root/dist/SneakPeek.app"
task_scratch="$task_root/.build"
task_bundle_id="local.sneakpeek.mission"
task_triple=""
while (( $# )); do
  case "$1" in
    --scratch-path) task_scratch="$2"; shift 2 ;;
    --app) task_app="$2"; shift 2 ;;
    --bundle-id) task_bundle_id="$2"; shift 2 ;;
    --triple) task_triple="$2"; shift 2 ;;
    *) print -u2 "Unknown build option: $1"; exit 2 ;;
  esac
done
mkdir -p "$task_scratch/cache"
task_target_args=()
if [[ -n "$task_triple" ]]; then task_target_args=(--triple "$task_triple"); fi
CLANG_MODULE_CACHE_PATH="$task_scratch/cache" swift build -c release --scratch-path "$task_scratch" "${task_target_args[@]}"
task_binary_dir="$(CLANG_MODULE_CACHE_PATH="$task_scratch/cache" swift build -c release --scratch-path "$task_scratch" "${task_target_args[@]}" --show-bin-path)"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/bridge"
cp "$task_binary_dir/SneakPeek" "$task_app/Contents/MacOS/SneakPeek"
cp -R "$task_binary_dir/SneakPeek_SneakPeek.bundle" "$task_app/Contents/Resources/"
if [[ "$task_bundle_id" != "local.sneakpeek.cove.demo" && "$task_bundle_id" != "local.sneakpeek.cove.gestures" ]]; then
  cp bridge/*.py "$task_app/Contents/Resources/bridge/"
fi
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SneakPeek</string>
<key>CFBundleIdentifier</key><string>local.sneakpeek.mission</string>
<key>CFBundleName</key><string>SneakPeek</string>
<key>CFBundleDisplayName</key><string>SneakPeek</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_bundle_id" "$task_app/Contents/Info.plist"
if [[ "$task_bundle_id" == "local.sneakpeek.cove.demo" || "$task_bundle_id" == "local.sneakpeek.cove.gestures" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Cove Demo" "$task_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Cove Demo" "$task_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0" "$task_app/Contents/Info.plist"
fi
if [[ "$task_bundle_id" == "local.sneakpeek.cove.gestures" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Cove Gestures" "$task_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Cove Gestures" "$task_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.1.0" "$task_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 5" "$task_app/Contents/Info.plist"
fi
codesign --force --sign - "$task_app"
print "Built $task_app"
