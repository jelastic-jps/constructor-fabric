#!/bin/sh
set -eu
export DISPLAY=:2
export HOME="${HOME:-/home/developer}"
export USER="${USER:-developer}"
export XDG_CURRENT_DESKTOP=LXDE
export DESKTOP_SESSION=LXDE
mkdir -p "${HOME}/constructor-fabric" "${HOME}/.config/pcmanfm/LXDE" "${HOME}/.config/lxpanel/LXDE/panels" "${HOME}/.config/libfm"
sudo mkdir -p /tmp/.X11-unix
sudo chmod 1777 /tmp/.X11-unix

# --- KILL ALL VNC/noVNC/websockify processes (from base image) ---
sudo pkill -9 -f x11vnc 2>/dev/null || true
sudo pkill -9 -f websockify 2>/dev/null || true
sudo pkill -9 -f novnc 2>/dev/null || true
sudo pkill -9 -f Xvfb 2>/dev/null || true
# Stop supervisor from restarting VNC
if [ -f /etc/supervisor/conf.d/supervisord.conf ]; then
  sudo python3 -c "
from pathlib import Path
p = Path('/etc/supervisor/conf.d/supervisord.conf')
s = p.read_text()
# Comment out all VNC-related programs
import re
s = re.sub(r'(^\[program:(x11vnc|novnc|websockify)\])', r'# DISABLED \1', s, flags=re.MULTILINE)
s = re.sub(r'(^(?:command|autostart)\s*=)', r'# DISABLED \1', s, flags=re.MULTILINE)
p.write_text(s)
" 2>/dev/null || true
  sudo supervisorctl stop x11vnc 2>/dev/null || true
  sudo supervisorctl stop novnc 2>/dev/null || true
  sudo supervisorctl stop websockify 2>/dev/null || true
  sudo supervisorctl reread 2>/dev/null || true
  sudo supervisorctl update 2>/dev/null || true
fi
sleep 1
sudo pkill -9 -f x11vnc 2>/dev/null || true
sudo pkill -9 -f websockify 2>/dev/null || true

# Audio: provide PulseAudio endpoint for Electron/Chromium apps
export ALSADEV="${ALSADEV:-default}"
export PULSE_RUNTIME_PATH=/tmp/pulse-root
export PULSE_SERVER=unix:/tmp/pulse-root/native
export SDL_AUDIODRIVER=pulse
export AUDIODEV=default
mkdir -p /tmp/pulse-root "${HOME}/.config/pulse"
sudo mkdir -p /dev/snd
sudo chmod 755 /dev/snd
chmod 700 /tmp/pulse-root || true
cat > "${HOME}/.config/pulse/client.conf" <<'PULSECLIENT'
default-server = unix:/tmp/pulse-root/native
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
PULSECLIENT
cat > "${HOME}/.asoundrc" <<'ASOUNDRC'
pcm.!default {
  type pulse
  fallback "nullsink"
  hint.description "Constructor Fabric virtual audio"
}
pcm.nullsink {
  type null
}
ctl.!default {
  type pulse
  fallback "nullctl"
}
ctl.nullctl {
  type hw
  card 0
}
ASOUNDRC
sudo cp "${HOME}/.asoundrc" /etc/asound.conf
if command -v pulseaudio >/dev/null 2>&1; then
  pulseaudio --kill >/dev/null 2>&1 || true
  pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit --log-target=file:"${HOME}/constructor-fabric/pulseaudio.log" || true
  if command -v pactl >/dev/null 2>&1; then
    for i in $(seq 1 20); do pactl info >/dev/null 2>&1 && break || sleep 0.2; done
    pactl load-module module-null-sink sink_name=virt_audio sink_properties=device.description=VirtualAudio >/dev/null 2>&1 || true
    pactl set-default-sink virt_audio >/dev/null 2>&1 || true
    pactl set-default-source virt_audio.monitor >/dev/null 2>&1 || true
  fi
fi

cat > "${HOME}/.config/libfm/libfm.conf" <<'LIBFM'
[config]
quick_exec=1
single_click=0
middle_click=0
LIBFM
if [ -f "${HOME}/constructor-fabric/app/wallpaper.png" ]; then
  cat > "${HOME}/.config/pcmanfm/LXDE/desktop-items-0.conf" <<WALLCONF
[*]
wallpaper_mode=fit
wallpaper=${HOME}/constructor-fabric/app/wallpaper.png
desktop_bg=#001838
show_documents=0
show_trash=0
show_mounts=0
WALLCONF
fi

start_detached() {
  name="$1"
  logfile="$2"
  shift 2
  if pgrep -f "$name" >/dev/null 2>&1; then
    echo "$name already running"
  else
    setsid "$@" </dev/null >"$logfile" 2>&1 &
  fi
}

RESOLUTION="${RESOLUTION:-1280x720}"
LOG_DIR="${HOME}/constructor-fabric"
mkdir -p "$LOG_DIR"

# --- Start Xvfb (needed for Electron trainer only) ---
rm -f /tmp/.X2-lock /tmp/.X11-unix/X2 2>/dev/null || true
setsid /usr/bin/Xvfb ${DISPLAY} -screen 0 ${RESOLUTION}x24 -ac +extension GLX +render -noreset </dev/null >"${LOG_DIR}/xvfb.log" 2>&1 &
sleep 1
x_ready=0
for i in $(seq 1 30); do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    x_ready=1
    break
  fi
  sleep 1
done
if [ "$x_ready" != "1" ]; then
  echo "Xvfb display ${DISPLAY} did not become ready; xvfb.log:" >&2
  tail -80 "${LOG_DIR}/xvfb.log" >&2 2>/dev/null || true
fi

# --- Landing page with nginx proxies for codium and trainer ---
if [ -f /etc/nginx/sites-enabled/default ]; then
  sudo rm -f /etc/nginx/sites-enabled/default.bak.*
  sudo python3 <<'PY'
from pathlib import Path
p = Path('/etc/nginx/sites-enabled/default')
if p.exists():
    s = p.read_text()
    # Remove HTTP basic auth
    import re
    s = re.sub(r'\n\s*auth_basic\s+[^;]+;\s*\n\s*auth_basic_user_file\s+[^;]+;\s*\n', '\n    # Constructor Fabric: no HTTP basic auth.\n    auth_basic off;\n', s, count=1)
    # Add /health endpoint
    if 'location = /health' not in s:
        health_loc = """
    location = /health {
        auth_basic off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass http://127.0.0.1:8081/health;
    }
"""
        for mk in ['\n    location / {\n', '\n\tlocation / {\n']:
            if mk in s:
                s = s.replace(mk, health_loc + mk, 1)
                break
        else:
            s = s.replace('\n}\n', health_loc + '\n}\n', 1)
    # Add /ide/ proxy
    additions = ''
    if 'location /ide/' not in s:
        additions += """
    location /ide/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
"""
    # Add /trainer/ proxy
    if 'location /trainer/' not in s:
        additions += """
    location /trainer/ {
        proxy_pass http://127.0.0.1:8082/;
        proxy_set_header Host $host;
    }
"""
    # Add /stable-<hash>/ proxy for codium serve-web assets
    # Codium HTML references absolute paths like /stable-<commit-hash>/static/...
    # which need to be proxied to port 8080
    if 'location ~' not in s:
        additions += """
    location ~ ^/stable-[a-f0-9]+/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
"""
    if additions:
        # Try space-indented markers first, then tab-indented
        for mk in ['\n    location / {\n', '\n\tlocation / {\n']:
            if mk in s:
                s = s.replace(mk, additions + mk, 1)
                break
        else:
            s = s.replace('\n}\n', additions + '\n}\n', 1)
    p.write_text(s)
PY
  # Deploy landing page
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  LANDING_SRC="${SCRIPT_DIR}/../assets/landing.html"
  if [ -f "$LANDING_SRC" ]; then
    sudo cp "$LANDING_SRC" /usr/local/lib/web/frontend/index.html
  elif [ -f "${HOME}/constructor-fabric/app/landing.html" ]; then
    sudo cp "${HOME}/constructor-fabric/app/landing.html" /usr/local/lib/web/frontend/index.html
  fi
  NGINX_BIN="$(command -v nginx || command -v /usr/sbin/nginx || true)"
  if [ -n "$NGINX_BIN" ]; then
    sudo "$NGINX_BIN" -t >"${LOG_DIR}/nginx-test.log" 2>&1 && \
      (sudo "$NGINX_BIN" -s reload || sudo service nginx reload || true) >"${LOG_DIR}/nginx-reload.log" 2>&1 || true
  fi
fi

# --- App server on port 8081 ---
start_detached "${HOME}/constructor-fabric/app/server.py" "${LOG_DIR}/app.log" python3 "${HOME}/constructor-fabric/app/server.py"

# --- Codium serve-web on port 8080 ---
if command -v codium >/dev/null 2>&1 || [ -x /usr/share/codium/bin/codium ]; then
  CODIUM_BIN="$(command -v codium || echo /usr/share/codium/bin/codium)"
  mkdir -p "${HOME}/.codium-server/data/Machine"
  # Write default settings for Continue extension
  if [ ! -f "${HOME}/.codium-server/data/Machine/settings.json" ]; then
    cat > "${HOME}/.codium-server/data/Machine/settings.json" <<'JSON'
{
  "workbench.startupEditor": "none",
  "terminal.integrated.defaultProfile.linux": "bash"
}
JSON
  fi
  # Install Continue extension for codium serve-web
  CODIUM_EXT_DIR="${HOME}/.codium-server/extensions"
  CODIUM_CACHE="${HOME}/.codium-server/data/CachedProfilesData/__default__profile__/extensions.builtin.cache"
  if [ -d "${HOME}/.config/VSCodium/extensions" ]; then
    # Copy any extensions from user dir to server extensions dir
    for ext_dir in "${HOME}"/.config/VSCodium/extensions/*/; do
      [ -d "$ext_dir" ] || continue
      ext_name=$(basename "$ext_dir")
      if [ ! -d "${CODIUM_EXT_DIR}/${ext_name}" ]; then
        cp -r "$ext_dir" "${CODIUM_EXT_DIR}/${ext_name}"
        echo "Copied extension: ${ext_name}"
      fi
    done
    # Register extensions in extensions.json if missing
    python3 -c "
import json, sys
from pathlib import Path
ext_dir = Path('${CODIUM_EXT_DIR}')
reg = ext_dir / 'extensions.json'
data = json.loads(reg.read_text()) if reg.exists() else []
ids = {e.get('identifier',{}).get('id') for e in data}
for d in ext_dir.iterdir():
    if d.is_dir() and (d / 'package.json').exists():
        pkg = json.loads((d / 'package.json').read_text())
        publisher = pkg.get('publisher', '')
        name = pkg.get('name', '')
        ext_id = f'{publisher}.{name}' if publisher else name
        if ext_id and ext_id not in ids:
            data.append({
                'identifier': {'id': ext_id},
                'version': pkg.get('version', ''),
                'location': {'\$mid': 1, 'fsPath': str(d), 'external': f'file://{d}', 'path': str(d), 'scheme': 'file'},
                'relativeLocation': d.name
            })
            print(f'Registered: {ext_id}')
reg.write_text(json.dumps(data, indent=2))
" 2>/dev/null || true
    # Clear extension cache so codium re-discovers extensions
    rm -f "${CODIUM_CACHE}" 2>/dev/null || true
  fi
  # Configure Continue extension with API key
  CONTINUE_CONFIG="${HOME}/.continue/config.json"
  if [ -n "${CONTINUE_API_KEY:-}" ] && [ ! -f "${CONTINUE_CONFIG}" ]; then
    mkdir -p "${HOME}/.continue"
    CONTINUE_API_BASE="${CONTINUE_API_BASE:-https://api.openai.com/v1}"
    CONTINUE_MODEL="${CONTINUE_MODEL:-gpt-4o}"
    cat > "${CONTINUE_CONFIG}" <<CONTINUEJSON
{
  "models": [{
    "title": "${CONTINUE_MODEL}",
    "provider": "openai",
    "model": "${CONTINUE_MODEL}",
    "apiBase": "${CONTINUE_API_BASE}",
    "apiKey": "${CONTINUE_API_KEY}"
  }],
  "tabAutocompleteModel": {
    "title": "${CONTINUE_MODEL}",
    "provider": "openai",
    "model": "${CONTINUE_MODEL}",
    "apiBase": "${CONTINUE_API_BASE}",
    "apiKey": "${CONTINUE_API_KEY}"
  },
  "allowAnonymousTelemetry": false
}
CONTINUEJSON
    chown -R "$(id -u):$(id -g)" "${HOME}/.continue" 2>/dev/null || true
  fi
  start_detached "codium serve-web" "${LOG_DIR}/codium-serve.log" \
    "${CODIUM_BIN}" serve-web --port 8080 --host 0.0.0.0 --without-connection-token --server-data-dir "${HOME}/.codium-server"
fi

# --- Trainer HTTP server on port 8082 ---
if [ -d "${HOME}/constructor-fabric/trainer" ]; then
  start_detached "trainer http" "${LOG_DIR}/trainer-http.log" \
    python3 -m http.server 8082 --directory "${HOME}/constructor-fabric/trainer" --bind 0.0.0.0
fi

# --- Cyber-constructor auto-bootstrap (if present) ---
if [ -x "${HOME}/cyber-constructor/auto-bootstrap.sh" ]; then
  start_detached "${HOME}/cyber-constructor/auto-bootstrap.sh" "${HOME}/cyber-constructor/auto-bootstrap-launch.log" "${HOME}/cyber-constructor/auto-bootstrap.sh"
fi

# --- Electron trainer (if present) ---
if [ -x "${HOME}/constructor-fabric/run-trainer.sh" ]; then
  start_detached 'constructor-fabric/trainer' "${LOG_DIR}/electron-trainer-launch.log" "${HOME}/constructor-fabric/run-trainer.sh"
fi
