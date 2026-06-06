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

    location = /favicon.ico {
        try_files /landing/favicon.ico /favicon.ico =404;
        access_log off;
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
  # Generate favicon.ico (16x16 dark grey PNG)
  FAVICON_DST="${HOME}/constructor-fabric/landing/favicon.ico"
  if [ ! -f "$FAVICON_DST" ]; then
    mkdir -p "${HOME}/constructor-fabric/landing"
    python3 -c "
import struct, zlib
width, height = 16, 16
raw = b''
for y in range(height):
    raw += b'\\x00'
    for x in range(width):
        raw += b'\\x33\\x33\\x33\\xff'
def chunk(ctype, data):
    c = ctype + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
png = b'\\x89PNG\\r\\n\\x1a\\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')
with open('$FAVICON_DST', 'wb') as f:
    f.write(png)
" 2>/dev/null || true
    sudo chown developer:developer "$FAVICON_DST" 2>/dev/null || true
  fi
  NGINX_BIN="$(command -v nginx || command -v /usr/sbin/nginx || true)"
  if [ -n "$NGINX_BIN" ]; then
    sudo "$NGINX_BIN" -t >"${LOG_DIR}/nginx-test.log" 2>&1 && \
      (sudo "$NGINX_BIN" -s reload || sudo service nginx reload || true) >"${LOG_DIR}/nginx-reload.log" 2>&1 || true
  fi
fi

# --- App server on port 8081 ---
start_detached "${HOME}/constructor-fabric/app/server.py" "${LOG_DIR}/app.log" python3 "${HOME}/constructor-fabric/app/server.py"

# --- Codium serve-web on port 8080 (supervisor-managed) ---
if command -v codium >/dev/null 2>&1 || [ -x /usr/share/codium/bin/codium ]; then
  CODIUM_BIN="$(command -v codium || echo /usr/share/codium/bin/codium)"
  mkdir -p "${HOME}/.codium-server/data/Machine"
  # Write default settings
  if [ ! -f "${HOME}/.codium-server/data/Machine/settings.json" ]; then
    cat > "${HOME}/.codium-server/data/Machine/settings.json" <<'JSON'
{
  "workbench.startupEditor": "none",
  "terminal.integrated.defaultProfile.linux": "bash"
}
JSON
  fi
  # Symlink baked-in extensions so codium serve-web discovers them
  BAKED_EXT_DIR="${HOME}/.vscodium-server/extensions"
  CODIUM_EXT_DIR="${HOME}/.codium-server/extensions"
  mkdir -p "$BAKED_EXT_DIR"  # ensure parent dir exists
  if [ -d "$BAKED_EXT_DIR" ] && [ ! -L "$CODIUM_EXT_DIR" ]; then
    rm -rf "$CODIUM_EXT_DIR" 2>/dev/null || true
    ln -sf "$BAKED_EXT_DIR" "$CODIUM_EXT_DIR"
    chown -h "$(id -u):$(id -g)" "$CODIUM_EXT_DIR" 2>/dev/null || true
    echo "Symlinked extensions: ${CODIUM_EXT_DIR} -> ${BAKED_EXT_DIR}"
  fi
  # Also symlink to .config/VSCodium/extensions (secondary registry)
  CONFIG_EXT_DIR="${HOME}/.config/VSCodium/extensions"
  mkdir -p "${HOME}/.config/VSCodium"
  if [ -d "$BAKED_EXT_DIR" ] && [ ! -L "$CONFIG_EXT_DIR" ]; then
    rm -rf "$CONFIG_EXT_DIR" 2>/dev/null || true
    ln -sf "$BAKED_EXT_DIR" "$CONFIG_EXT_DIR"
    chown -h "$(id -u):$(id -g)" "$CONFIG_EXT_DIR" 2>/dev/null || true
  fi
  rm -f "${HOME}/.codium-server/data/CachedProfilesData" 2>/dev/null || true
  # Ensure developer owns their entire home
  chown -R developer:developer "${HOME}"
  # Install Cody AI extension (web-compatible, unlike Continue)
  if [ -x "$CODIUM_BIN" ]; then
    sudo -u developer -H "$CODIUM_BIN" --install-extension sourcegraph.cody-ai 2>/dev/null || true
    sudo -u developer -H "$CODIUM_BIN" --install-extension tabbyml.vscode-tabby 2>/dev/null || true
    # Ensure extensions installed to standard path (~/.vscode-oss/extensions/) are
    # discoverable by codium serve-web which uses ~/.codium-server/extensions/
    USER_EXT_DIR="${HOME}/.vscode-oss/extensions"
    if [ -d "$USER_EXT_DIR" ] && [ -d "$CODIUM_EXT_DIR" ]; then
      for ext in "$USER_EXT_DIR"/sourcegraph.cody-ai-* "$USER_EXT_DIR"/TabbyML.vscode-tabby-*; do
        [ -d "$ext" ] || continue
        ext_name="$(basename "$ext")"
        if [ ! -d "${CODIUM_EXT_DIR}/${ext_name}" ]; then
          ln -sf "$ext" "${CODIUM_EXT_DIR}/${ext_name}" 2>/dev/null || true
          echo "Symlinked extension: ${ext_name} -> ${CODIUM_EXT_DIR}/"
        fi
      done
    fi
    # Remove .obsolete markers that block extension loading
    rm -f "${HOME}/.codium-server/extensions/.obsolete" 2>/dev/null || true
    rm -f "${HOME}/.config/VSCodium/extensions/.obsolete" 2>/dev/null || true
    rm -f "${USER_EXT_DIR}/.obsolete" 2>/dev/null || true
    # Fix ownership after extension install
    chown -R developer:developer "${HOME}/.vscode-oss" "${HOME}/.codium-server" "${HOME}/.config/VSCodium" 2>/dev/null || true
  fi
  # Create supervisor config for codium (persistent, auto-restart)
  sudo tee /etc/supervisor/conf.d/codium.conf > /dev/null <<SUPERVISOR
[program:codium]
command=${CODIUM_BIN} --no-sandbox serve-web --port 8080 --host 0.0.0.0 --without-connection-token --server-base-path /ide
user=developer
environment=HOME="${HOME}"
directory=${HOME}
autostart=true
autorestart=true
startsecs=5
stdout_logfile=${LOG_DIR}/codium-serve.log
stderr_logfile=${LOG_DIR}/codium-serve.log
stdout_logfile_maxbytes=5MB
SUPERVISOR
  echo "Supervisor codium config created"
fi

# --- Trainer HTTP server on port 8082 (supervisor-managed) ---
if [ -d "${HOME}/constructor-fabric/trainer" ]; then
  # Kill any existing manual trainer process
  fuser -k 8082/tcp 2>/dev/null || true
  sudo tee /etc/supervisor/conf.d/trainer.conf > /dev/null <<SUPERVISOR
[program:trainer]
command=python3 -m http.server 8082 --directory ${HOME}/constructor-fabric/trainer --bind 0.0.0.0
user=developer
directory=${HOME}/constructor-fabric/trainer
autostart=true
autorestart=true
startsecs=3
stdout_logfile=${LOG_DIR}/trainer-http.log
stderr_logfile=${LOG_DIR}/trainer-http.log
stdout_logfile_maxbytes=2MB
SUPERVISOR
  echo "Supervisor trainer config created"
fi

# --- Apply supervisor configs ---
if command -v supervisorctl >/dev/null 2>&1; then
  sudo supervisorctl reread 2>/dev/null || true
  sudo supervisorctl update 2>/dev/null || true
  sleep 3
  sudo supervisorctl status 2>/dev/null || true
fi

# --- Cyber-constructor auto-bootstrap (if present) ---
if [ -x "${HOME}/cyber-constructor/auto-bootstrap.sh" ]; then
  start_detached "${HOME}/cyber-constructor/auto-bootstrap.sh" "${HOME}/cyber-constructor/auto-bootstrap-launch.log" "${HOME}/cyber-constructor/auto-bootstrap.sh"
fi

# --- Electron trainer (if present) ---
if [ -x "${HOME}/constructor-fabric/run-trainer.sh" ]; then
  start_detached 'constructor-fabric/trainer' "${LOG_DIR}/electron-trainer-launch.log" "${HOME}/constructor-fabric/run-trainer.sh"
fi
