#!/bin/zsh
# Builds Remote Mounts.app. `./build.sh install` also quits the running copy,
# installs to ~/Applications and relaunches it.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
APP="build/Remote Mounts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RemoteMounts "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ ${1:-} == install ]]; then
  # Quit politely so the running copy unmounts everything first
  if pgrep -xq RemoteMounts; then
    osascript -e 'tell application id "dev.josu.RemoteMounts" to quit' || true
    for _ in {1..300}; do pgrep -xq RemoteMounts || break; sleep 0.2; done
    if pgrep -xq RemoteMounts; then
      echo "Remote Mounts is still running (waiting for uploads?); quit it and run again" >&2
      exit 1
    fi
  fi
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Remote Mounts.app"
  ditto "$APP" ~/Applications/"Remote Mounts.app"
  open ~/Applications/"Remote Mounts.app"
  echo "installed and launched ~/Applications/Remote Mounts.app"
fi
