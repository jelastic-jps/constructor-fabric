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
    s = re.sub(r'\n\s*auth_basic\s+[^;]+;\s*\n\s*auth_basic_user_file\s+[^;]+;\s*\n', '\n\t# Constructor Fabric: no HTTP basic auth.\n\tauth_basic off;\n', s, count=1)
    # Add /health endpoint
    if 'location = /health' not in s:
        health_loc = """
\tlocation = /health {
\t\tauth_basic off;
\t\tproxy_set_header Host $host;
\t\tproxy_set_header X-Real-IP $remote_addr;
\t\tproxy_pass http://127.0.0.1:8081/health;
\t}
"""
        marker = '\n\tlocation / {\n'
        if marker in s:
            s = s.replace(marker, health_loc + marker, 1)
        else:
            s = s.replace('\n}\n', health_loc + '\n}\n', 1)
    # Add /ide/ proxy
    additions = ''
    if 'location /ide/' not in s:
        additions += """
\tlocation /ide/ {
\t\tproxy_pass http://127.0.0.1:8080/;
\t\tproxy_set_header Host $host;
\t\tproxy_set_header Upgrade $http_upgrade;
\t\tproxy_set_header Connection "upgrade";
\t\tproxy_read_timeout 86400;
\t}
"""
    # Add /trainer/ proxy
    if 'location /trainer/' not in s:
        additions += """
\tlocation /trainer/ {
\t\tproxy_pass http://127.0.0.1:8082/;
\t\tproxy_set_header Host $host;
\t}
"""
    if additions:
        marker = '\n\tlocation / {\n'
        if marker in s:
            s = s.replace(marker, additions + marker, 1)
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
