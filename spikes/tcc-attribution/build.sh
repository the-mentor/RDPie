#!/bin/sh
# Builds probe-agent and assembles it into an ad-hoc signed Probe.app,
# matching the Contents/MacOS + Contents/Library/LaunchAgents layout spec
# §4.1 requires for the real daemon. Output is untracked build/.
set -eu
cd "$(dirname "$0")"

swift build -c release

APP=build/Probe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"

cp .build/release/probe-agent "$APP/Contents/MacOS/probe-agent"
cp Info.plist "$APP/Contents/Info.plist"
cp com.rdpie.tccprobe.plist "$APP/Contents/Library/LaunchAgents/com.rdpie.tccprobe.plist"

codesign --force --deep --sign - "$APP"

echo "Built $APP"
