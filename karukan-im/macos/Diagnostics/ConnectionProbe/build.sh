#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$source_dir/../../../.." && pwd)"
output_dir="${1:-$repo_dir/.work/connection-probe-v5}"
mkdir -p "$output_dir/module-cache"
output_dir="$(cd -- "$output_dir" && pwd)"
app="$output_dir/Karukan Connection Probe.app"
if pgrep -f "$app/Contents/MacOS/KarukanConnectionProbe" >/dev/null; then
    echo 'Close the connection probe before replacing its signed bundle.' >&2
    exit 2
fi
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$output_dir/module-cache" \
    -c "$source_dir/ContextTrace.m" -o "$output_dir/ContextTrace.o"
xcrun swiftc -swift-version 5 -module-cache-path "$output_dir/module-cache" \
    -import-objc-header "$source_dir/ContextTrace.h" \
    "$source_dir/Probe.swift" "$output_dir/ContextTrace.o" \
    -o "$output_dir/KarukanConnectionProbe"
cp "$output_dir/KarukanConnectionProbe" "$app/Contents/MacOS/KarukanConnectionProbe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KarukanConnectionProbe</string>
<key>CFBundleIdentifier</key><string>dev.kazuhideoki.KarukanConnectionProbe</string>
<key>CFBundleName</key><string>Karukan Connection Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>5</string>
<key>NSPrincipalClass</key><string>ProbeApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
for helper in PhysicalKeyProbe SelectProbeSource; do
    xcrun swiftc -swift-version 5 -module-cache-path "$output_dir/module-cache" \
        "$source_dir/$helper.swift" -o "$output_dir/$helper"
done
printf '%s\n' "$app"
