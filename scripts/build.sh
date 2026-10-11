#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
mkdir -p .build/cache
CLANG_MODULE_CACHE_PATH="$task_root/.build/cache" swift build -c release --scratch-path "$task_root/.build"
task_app="$task_root/dist/SneakPeek.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/bridge"
cp .build/release/SneakPeek "$task_app/Contents/MacOS/SneakPeek"
cp bridge/*.py "$task_app/Contents/Resources/bridge/"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SneakPeek</string>
<key>CFBundleIdentifier</key><string>local.sneakpeek.mission</string>
<key>CFBundleName</key><string>SneakPeek</string>
<key>CFBundleDisplayName</key><string>SneakPeek</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$task_app"
print "Built $task_app"
