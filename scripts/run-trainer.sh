#!/bin/sh
set -u
export HOME="${HOME:-/home/developer}"
export DISPLAY="${DISPLAY:-:1}"
export PATH="${HOME}/constructor-fabric/trainer/node_modules/.bin:/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG="${HOME}/constructor-fabric/electron-trainer.log"
mkdir -p "${HOME}/constructor-fabric/trainer"
printf "[%s] starting trainer\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG"
ensure_electron(){
  if command -v electron >/dev/null 2>&1 && electron --no-sandbox --version >>"$LOG" 2>&1; then
    return 0
  fi
  if [ -x /opt/node-current/bin/npm ]; then
    rm -rf "${HOME}/constructor-fabric/trainer/node_modules/electron"
    /opt/node-current/bin/npm install --prefix "${HOME}/constructor-fabric/trainer" electron@latest >>"$LOG" 2>&1 || true
  fi
  command -v electron >/dev/null 2>&1 && electron --no-sandbox --version >>"$LOG" 2>&1
}
if ensure_electron; then
  exec electron --no-sandbox --disable-gpu "${HOME}/constructor-fabric/trainer"
fi
echo "Electron is required for the Constructor Fabric Trainer but is not available or failed to start." >&2
echo "Electron is required for the Constructor Fabric Trainer but is not available or failed to start." >>"$LOG"
exit 1
