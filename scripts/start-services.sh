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

# --- Code-server on port 8080 (supervisor-managed) ---
if command -v code-server >/dev/null 2>&1; then
  CS_WORKSPACE="${HOME}/workspaces/constructor-fabric-workspace"
  mkdir -p "$CS_WORKSPACE" "${HOME}/.config/code-server"

  # Configure code-server
  cat > "${HOME}/.config/code-server/config.yaml" <<'CSSERVER'
bind-addr: 0.0.0.0:8080
auth: none
cert: false
CSSERVER

  # Install Continue extension (uses API tokens from ~/.continue/config.yaml)
  if ! code-server --list-extensions 2>/dev/null | grep -qi 'Continue.continue'; then
    echo "Installing Continue extension for code-server..."
    sudo -u developer -H code-server --install-extension Continue.continue 2>/dev/null || echo "Continue install failed"
  fi

  # Install Copilot extension from VSIX (not available on open-vsx)
  if ! code-server --list-extensions 2>/dev/null | grep -qi 'github.copilot'; then
    echo "Installing GitHub Copilot extension for code-server..."
    COPIL_VSIX="/tmp/copilot.vsix"
    curl --noproxy '*' -fsSL \
      'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage' \
      -o "$COPIL_VSIX" 2>/dev/null \
      && sudo -u developer -H code-server --install-extension "$COPIL_VSIX" 2>/dev/null \
      || echo "Copilot VSIX install failed"
    rm -f "$COPIL_VSIX" 2>/dev/null || true
  fi

  # Install Copilot Chat extension from VSIX
  if ! code-server --list-extensions 2>/dev/null | grep -qi 'github.copilot-chat'; then
    echo "Installing GitHub Copilot Chat extension for code-server..."
    COPILCHAT_VSIX="/tmp/copilot-chat.vsix"
    curl --noproxy '*' -fsSL \
      'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot-chat/latest/vspackage' \
      -o "$COPILCHAT_VSIX" 2>/dev/null \
      && sudo -u developer -H code-server --install-extension "$COPILCHAT_VSIX" 2>/dev/null \
      || echo "Copilot Chat VSIX install failed"
    rm -f "$COPILCHAT_VSIX" 2>/dev/null || true
  fi

  chown -R developer:developer "${HOME}/.config/code-server" "${HOME}/.local/share/code-server" 2>/dev/null || true

  # Download trainer HTML and patch code-server welcome page
  TRAINER_HTML="${CS_WORKSPACE}/.trainer-welcome.html"
  if [ ! -f "$TRAINER_HTML" ]; then
    curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/main/trainer/index.html" -o "$TRAINER_HTML" 2>/dev/null || true
    chown developer:developer "$TRAINER_HTML" 2>/dev/null || true
  fi
  # Patch product.json to show trainer as welcome page
  PRODUCT_JSON="$(find /usr/lib/code-server /usr/share/code-server -name product.json -path '*/vscode/*' 2>/dev/null | head -1)"
  if [ -n "$PRODUCT_JSON" ] && [ -f "$PRODUCT_JSON" ]; then
    python3 -c "
    import json
    from pathlib import Path
    p = Path('$PRODUCT_JSON')
    data = json.loads(p.read_text())
    data['welcomePage'] = '$TRAINER_HTML'
    p.write_text(json.dumps(data, indent=2))
    print('product.json welcomePage set to trainer')
    " 2>/dev/null || true
  fi

  # Create supervisor config for code-server
  sudo tee /etc/supervisor/conf.d/code-server.conf > /dev/null <<SUPERVISOR
[program:code-server]
command=code-server --bind-addr 0.0.0.0:8080 --auth none --disable-telemetry ${CS_WORKSPACE}
user=developer
environment=HOME="${HOME}"
directory=${CS_WORKSPACE}
autostart=true
autorestart=true
startsecs=5
stdout_logfile=${LOG_DIR}/code-server.log
stderr_logfile=${LOG_DIR}/code-server.log
stdout_logfile_maxbytes=5MB
SUPERVISOR
  echo "Supervisor code-server config created"
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
  # Clean ALL x11vnc/novnc/websockify references from supervisor configs
  for f in /etc/supervisor/conf.d/*.conf; do
    [ -f "$f" ] || continue
    sudo sed -i '/x11vnc/d' "$f" 2>/dev/null || true
    sudo sed -i '/novnc/d' "$f" 2>/dev/null || true
    sudo sed -i '/websockify/d' "$f" 2>/dev/null || true
  done
  # Remove empty program blocks
  for f in /etc/supervisor/conf.d/*.conf; do
    [ -f "$f" ] || continue
    sudo python3 -c "
    import re
    from pathlib import Path
    p = Path('$f')
    text = p.read_text()
    # Remove program blocks that have no command= line
    text = re.sub(r'\[program:[^\]]+\]\n(?:(?!command=).)*\n*', '', text)
    p.write_text(text)
    " 2>/dev/null || true
  done
  # Reload supervisor
  sudo supervisorctl reread 2>/dev/null || true
  sudo supervisorctl update 2>/dev/null || true
  sleep 5
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
