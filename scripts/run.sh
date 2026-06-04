#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/OpenCall Mac.app"
if [ ! -d "$APP" ]; then
  scripts/build.sh >/dev/null
fi
osascript -e 'tell application id "local.opencall.mac" to quit' >/dev/null 2>&1 || true
sleep 0.3
open "$APP"
