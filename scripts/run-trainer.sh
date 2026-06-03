#!/bin/sh
set -u
export HOME="${HOME:-/home/developer}"
export DISPLAY="${DISPLAY:-:1}"
export PATH="${HOME}/constructor-fabric/trainer/node_modules/.bin:/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
LOG="${HOME}/constructor-fabric/electron-trainer.log"
TRAINER_DIR="${HOME}/constructor-fabric/trainer"
LOCAL_ELECTRON="${TRAINER_DIR}/node_modules/.bin/electron"
mkdir -p "$TRAINER_DIR"
printf "[%s] starting trainer\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$LOG"
ensure_electron(){
  if [ -x "$LOCAL_ELECTRON" ] && "$LOCAL_ELECTRON" --no-sandbox --version >>"$LOG" 2>&1; then
    return 0
  fi
  if [ -x /opt/node-current/bin/npm ]; then
    rm -rf "${TRAINER_DIR}/node_modules/electron"
    /opt/node-current/bin/npm install --prefix "$TRAINER_DIR" electron@latest >>"$LOG" 2>&1 || true
  fi
  if [ -x "$LOCAL_ELECTRON" ] && "$LOCAL_ELECTRON" --no-sandbox --version >>"$LOG" 2>&1; then
    return 0
  fi
  if command -v electron >/dev/null 2>&1 && electron --no-sandbox --version >>"$LOG" 2>&1; then
    return 0
  fi
  return 1
}
if ensure_electron; then
  if [ -x "$LOCAL_ELECTRON" ]; then
    exec "$LOCAL_ELECTRON" --no-sandbox --disable-gpu "$TRAINER_DIR"
  fi
  exec electron --no-sandbox --disable-gpu "$TRAINER_DIR"
fi
echo "Electron is required for the Constructor Fabric Trainer but is not available or failed to start." >&2
echo "Electron is required for the Constructor Fabric Trainer but is not available or failed to start." >>"$LOG"
exit 1
