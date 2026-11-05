#!/bin/bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$source_dir/../../../.." && pwd)"
output_dir="${1:-$repo_dir/.work/connection-probe-lab}"
mkdir -p "$output_dir/module-cache"
output_dir="$(cd -- "$output_dir" && pwd)"
bundle_id="dev.kazuhideoki.KarukanConnectionProbe.h$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' "$output_dir")"
app="$output_dir/Karukan Connection Probe.app"
if pgrep -f "$app/Contents/MacOS/KarukanConnectionProbe" >/dev/null; then
    echo 'Close the connection probe before replacing its signed bundle.' >&2
    exit 2
else
    status=$?
    if [ "$status" -ne 1 ]; then
        echo 'Could not check whether the probe is running; bundle not replaced.' >&2
        exit "$status"
    fi
fi
mkdir -p "$app/Contents/MacOS"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$output_dir/module-cache" \
    -c "$source_dir/ContextTrace.m" -o "$output_dir/ContextTrace.o"
xcrun swiftc -swift-version 5 -module-cache-path "$output_dir/module-cache" \
    -import-objc-header "$source_dir/ContextTrace.h" \
    "$source_dir/Probe.swift" "$output_dir/ContextTrace.o" \
    -o "$output_dir/KarukanConnectionProbe"
cp "$output_dir/KarukanConnectionProbe" "$app/Contents/MacOS/KarukanConnectionProbe"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>KarukanConnectionProbe</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>Karukan Connection Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>6</string>
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
