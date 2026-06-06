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
  # Remove x11vnc from supervisor config using sed
  sudo sed -i '/\[program:x11vnc\]/,/\[program:/d' /etc/supervisor/conf.d/supervisord.conf 2>/dev/null || true
  # If x11vnc was the last block, remove to end of file
  sudo sed -i '/\[program:x11vnc\]/,$d' /etc/supervisor/conf.d/supervisord.conf 2>/dev/null || true
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
    if [ -n "${RUN_AS_USER:-}" ]; then
      setsid sudo -u "$RUN_AS_USER" -H "$@" </dev/null >"$logfile" 2>&1 &
    else
      setsid "$@" </dev/null >"$logfile" 2>&1 &
    fi
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
  # Generate self-signed TLS cert for secure context (crypto.subtle requires HTTPS)
  sudo mkdir -p /etc/nginx/ssl
  if [ ! -f /etc/nginx/ssl/server.crt ]; then
    DETECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')"
    sudo openssl req -x509 -nodes -days 3650 \
      -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/server.key \
      -out /etc/nginx/ssl/server.crt \
      -subj "/CN=constructor-fabric/O=Virtuozzo/C=US" \
      -addext "subjectAltName=IP:${DETECTED_IP},DNS:$(hostname)" \
      2>/dev/null || true
    echo "Self-signed TLS cert generated for ${DETECTED_IP}"
  fi
  # Write complete HTTPS nginx config (replaces Jelastic default)
  sudo tee /etc/nginx/sites-enabled/default > /dev/null <<'NGINX'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /home/developer/constructor-fabric;
    index landing.html;

    auth_basic off;

    location = /health {
        auth_basic off;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass http://127.0.0.1:8081/health;
    }

    location /ide/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        sub_filter "localhost:8080" "$host";
        sub_filter_once off;
        sub_filter_types text/html application/javascript;
    }

    location /trainer/ {
        proxy_pass http://127.0.0.1:8082/;
        proxy_set_header Host $host;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX
  sudo rm -f /etc/nginx/sites-enabled/default.bak.*
  # Deploy landing page to nginx root directory
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  LANDING_SRC="${SCRIPT_DIR}/../assets/landing.html"
  LANDING_DST="${HOME}/constructor-fabric/landing.html"
  if [ -f "$LANDING_SRC" ]; then
    sudo cp "$LANDING_SRC" "$LANDING_DST"
    sudo chown developer:developer "$LANDING_DST"
  elif [ -f "${HOME}/constructor-fabric/app/landing.html" ]; then
    sudo cp "${HOME}/constructor-fabric/app/landing.html" "$LANDING_DST"
    sudo chown developer:developer "$LANDING_DST"
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
  # Symlink baked-in extensions so codium serve-web discovers them
  # Baked-in extensions live at ~/.vscodium-server/extensions (Docker image)
  # codium serve-web --server-data-dir ~/.codium-server looks at ~/.codium-server/extensions
  BAKED_EXT_DIR="${HOME}/.vscodium-server/extensions"
  CODIUM_EXT_DIR="${HOME}/.codium-server/extensions"
  if [ -d "$BAKED_EXT_DIR" ] && [ ! -L "$CODIUM_EXT_DIR" ]; then
    rm -rf "$CODIUM_EXT_DIR" 2>/dev/null || true
    ln -sf "$BAKED_EXT_DIR" "$CODIUM_EXT_DIR"
    chown -h "$(id -u):$(id -g)" "$CODIUM_EXT_DIR" 2>/dev/null || true
    echo "Symlinked extensions: ${CODIUM_EXT_DIR} -> ${BAKED_EXT_DIR}"
  fi
  rm -f "${HOME}/.codium-server/data/CachedProfilesData" 2>/dev/null || true
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
    chown -R developer:developer "${HOME}/.continue" 2>/dev/null || true
  fi
  # Ensure developer owns their entire home (prevents EACCES on .continue/index etc.)
  chown -R developer:developer "${HOME}"
  RUN_AS_USER=developer start_detached "codium serve-web" "${LOG_DIR}/codium-serve.log" \
    "${CODIUM_BIN}" serve-web --port 8080 --host 0.0.0.0 --without-connection-token \
    --server-data-dir "${HOME}/.codium-server" \
    --server-base-path /ide
fi

# --- Trainer HTTP server on port 8082 ---
if [ -d "${HOME}/constructor-fabric/trainer" ]; then
  RUN_AS_USER=developer start_detached "trainer http" "${LOG_DIR}/trainer-http.log" \
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
