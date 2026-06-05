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
# Audio: provide a real PulseAudio endpoint for Electron/Chromium apps so they do
# not emit the base-image "To support audio, please read README" warning. Browser
# audio forwarding is platform-dependent, but apps must at least see a working sink.
export ALSADEV="${ALSADEV:-default}"
export PULSE_RUNTIME_PATH=/tmp/pulse-root
export PULSE_SERVER=unix:/tmp/pulse-root/native
export SDL_AUDIODRIVER=pulse
export AUDIODEV=default
# The upstream desktop image documents audio as: --device /dev/snd -e ALSADEV=hw:2,0.
# For this marketplace desktop real sound is not required, but some launchers/apps
# only check that ALSADEV and /dev/snd exist before printing the noisy warning.
# Provide a harmless dummy /dev/snd directory plus Pulse/ALSA null routing.
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

if [ -f /etc/supervisor/conf.d/supervisord.conf ]; then
  sudo python3 <<'PYCONF'
from pathlib import Path
p = Path('/etc/supervisor/conf.d/supervisord.conf')
text = p.read_text()
text = text.replace('command=x11vnc -display :1 -xkb -forever -shared -repeat -rfbauth /.password2', 'command=x11vnc -display :1 -xkb -forever -shared -repeat -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -rfbauth /.password2')
p.write_text(text)
PYCONF
fi

configure_openbox_theme() {
  mkdir -p "${HOME}/.config/openbox" "${HOME}/.config/gtk-3.0" "${HOME}/.config/gtk-2.0"
  sudo mkdir -p /usr/share/themes/ConstructorFabric/openbox-3
  cat > /tmp/themerc <<'OBTHEME'
border.width: 2
padding.width: 6
padding.height: 5
window.client.padding.width: 0
window.handle.width: 4
window.active.border.color: #2dd4bf
window.inactive.border.color: #172944
window.active.title.bg: flat gradient vertical
window.active.title.bg.color: #132846
window.active.title.bg.colorTo: #0a1628
window.inactive.title.bg: flat gradient vertical
window.inactive.title.bg.color: #0c1728
window.inactive.title.bg.colorTo: #070d18
window.active.label.text.color: #eef6ff
window.inactive.label.text.color: #93a4b8
window.label.text.justify: center
window.active.handle.bg: flat solid
window.active.handle.bg.color: #0b1b31
window.inactive.handle.bg: flat solid
window.inactive.handle.bg.color: #07111f
window.active.grip.bg: flat solid
window.active.grip.bg.color: #2dd4bf
window.inactive.grip.bg: flat solid
window.inactive.grip.bg.color: #1f3554
window.active.button.unpressed.bg: flat solid
window.active.button.unpressed.bg.color: #183454
window.active.button.pressed.bg: flat solid
window.active.button.pressed.bg.color: #2dd4bf
window.active.button.hover.bg: flat solid
window.active.button.hover.bg.color: #2563eb
window.active.button.disabled.bg: flat solid
window.active.button.disabled.bg.color: #102039
window.active.button.unpressed.image.color: #e7f7ff
window.active.button.pressed.image.color: #04111f
window.active.button.hover.image.color: #ffffff
window.active.button.disabled.image.color: #5d7089
window.inactive.button.unpressed.bg: flat solid
window.inactive.button.unpressed.bg.color: #101d31
window.inactive.button.pressed.bg: flat solid
window.inactive.button.pressed.bg.color: #223957
window.inactive.button.hover.bg: flat solid
window.inactive.button.hover.bg.color: #1d3556
window.inactive.button.disabled.bg: flat solid
window.inactive.button.disabled.bg.color: #0b1524
window.inactive.button.unpressed.image.color: #93a4b8
window.inactive.button.pressed.image.color: #d8e9ff
window.inactive.button.hover.image.color: #d8e9ff
window.inactive.button.disabled.image.color: #3d4d63
menu.border.width: 1
menu.border.color: #2dd4bf
menu.title.bg: flat solid
menu.title.bg.color: #132846
menu.title.text.color: #eef6ff
menu.items.bg: flat solid
menu.items.bg.color: #07111f
menu.items.text.color: #d8e9ff
menu.items.active.bg: flat solid
menu.items.active.bg.color: #1e3a5f
menu.items.active.text.color: #ffffff
osd.bg: flat solid
osd.bg.color: #07111f
osd.border.width: 1
osd.border.color: #2dd4bf
osd.label.text.color: #eef6ff
OBTHEME
  sudo cp /tmp/themerc /usr/share/themes/ConstructorFabric/openbox-3/themerc

  cat > /tmp/close.xbm <<'OBXBM'
#define close_width 8
#define close_height 8
static unsigned char close_bits[] = { 0xc3,0xe7,0x7e,0x3c,0x3c,0x7e,0xe7,0xc3 };
OBXBM
  sudo cp /tmp/close.xbm /usr/share/themes/ConstructorFabric/openbox-3/close.xbm

  cat > /tmp/max.xbm <<'OBXBM'
#define max_width 8
#define max_height 8
static unsigned char max_bits[] = { 0xff,0x81,0x81,0x81,0x81,0x81,0x81,0xff };
OBXBM
  sudo cp /tmp/max.xbm /usr/share/themes/ConstructorFabric/openbox-3/max.xbm

  cat > /tmp/iconify.xbm <<'OBXBM'
#define iconify_width 8
#define iconify_height 8
static unsigned char iconify_bits[] = { 0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff };
OBXBM
  sudo cp /tmp/iconify.xbm /usr/share/themes/ConstructorFabric/openbox-3/iconify.xbm

  cat > /tmp/shade.xbm <<'OBXBM'
#define shade_width 8
#define shade_height 8
static unsigned char shade_bits[] = { 0x18,0x3c,0x7e,0xff,0x00,0x00,0x00,0x00 };
OBXBM
  sudo cp /tmp/shade.xbm /usr/share/themes/ConstructorFabric/openbox-3/shade.xbm

  cat > /tmp/desk.xbm <<'OBXBM'
#define desk_width 8
#define desk_height 8
static unsigned char desk_bits[] = { 0xff,0x81,0xbd,0xa5,0xa5,0xbd,0x81,0xff };
OBXBM
  sudo cp /tmp/desk.xbm /usr/share/themes/ConstructorFabric/openbox-3/desk.xbm

python3 - <<'PYOB'
from pathlib import Path
candidates = [
  Path('/etc/xdg/openbox/LXDE/rc.xml'),
  Path('/etc/xdg/openbox/rc.xml'),
  Path('/usr/share/openbox/rc.xml'),
  Path('/usr/share/lxde/openbox/rc.xml'),
]
p=Path.home() / '.config/openbox/lxde-rc.xml'
p.parent.mkdir(parents=True, exist_ok=True)
for src in candidates:
  if src.exists():
    p.write_text(src.read_text())
    break
else:
  p.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<openbox_config xmlns="http://openbox.org/3.4/rc"><theme><name>Onyx</name></theme><font><name>Sans</name><size>11</size></font></openbox_config>\n')
s=p.read_text().replace('<name>Onyx</name>', '<name>ConstructorFabric</name>').replace('<size>11</size>', '<size>12</size>')
p.write_text(s)
PYOB
  cat > "${HOME}/.config/gtk-3.0/settings.ini" <<'GTK3'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 11
GTK3
  cat > "${HOME}/.gtkrc-2.0" <<'GTK2'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Adwaita"
gtk-font-name="Sans 11"
GTK2
}

configure_lxpanel() {
  mkdir -p "${HOME}/.config/lxpanel/LXDE/panels"
  cat > "${HOME}/.config/lxpanel/LXDE/panels/panel" <<LXPANEL
# Constructor Fabric bottom panel with task switcher for minimized windows.
Global {
  edge=bottom
  allign=left
  margin=0
  widthtype=percent
  width=100
  height=36
  transparent=0
  tintcolor=#07111f
  alpha=235
  autohide=0
  heightwhenhidden=2
  setdocktype=1
  setpartialstrut=1
  usefontcolor=1
  fontcolor=#eef6ff
  background=0
  iconsize=24
}
Plugin {
  type=space
  Config {
    Size=6
  }
}
Plugin {
  type=menu
  Config {
    image=${HOME}/constructor-fabric/app/icon.png
    system {
    }
    separator {
    }
    item {
      name=Run
      image=system-run
      command=run
    }
    item {
      name=Terminal
      image=utilities-terminal
      command=lxterminal --working-directory=${HOME}/workspaces/constructor-fabric-workspace
    }
    item {
      name=Workspace
      image=folder
      command=pcmanfm ${HOME}/workspaces/constructor-fabric-workspace
    }
  }
}
Plugin {
  type=launchbar
  Config {
    Button {
      id=${HOME}/Desktop/Constructor-Fabric-Trainer.desktop
    }
    Button {
      id=${HOME}/Desktop/Chromium.desktop
    }
    Button {
      id=${HOME}/Desktop/Terminal.desktop
    }
    Button {
      id=${HOME}/Desktop/VS-Codium.desktop
    }
    Button {
      id=${HOME}/Desktop/Cursor.desktop
    }
    Button {
      id=${HOME}/Desktop/Windsurf.desktop
    }
  }
}
Plugin {
  type=space
  Config {
    Size=8
  }
}
Plugin {
  type=taskbar
  Config {
    tooltips=1
    IconsOnly=0
    ShowAllDesks=1
    UseMouseWheel=1
    UseUrgencyHint=1
    FlatButton=0
    MaxTaskWidth=260
    spacing=2
    GroupedTasks=0
  }
}
Plugin {
  type=space
  Config {
    Size=8
  }
}
Plugin {
  type=tray
}
Plugin {
  type=dclock
  Config {
    ClockFmt=%H:%M
    TooltipFmt=%A %x
    BoldFont=1
  }
}
LXPANEL
  cat > "${HOME}/.config/lxpanel/LXDE/config" <<'LXCONF'
[Command]
FileManager=pcmanfm %s
Terminal=lxterminal
Logout=lxsession-logout
LXCONF
}

configure_openbox_theme
configure_lxpanel

RESOLUTION="${RESOLUTION:-1280x720}"
VNC_LOG_DIR="${HOME}/constructor-fabric"
mkdir -p "$VNC_LOG_DIR"

# Bring up the X display deterministically. Stale Xvfb/x11vnc processes from the
# base image can remain after startup.sh; kill them and own the display/port.
pkill -x x11vnc >/dev/null 2>&1 || true
pkill -f "Xvfb ${DISPLAY}" >/dev/null 2>&1 || true
rm -f /tmp/.X2-lock /tmp/.X11-unix/X2 2>/dev/null || true
setsid /usr/bin/Xvfb ${DISPLAY} -screen 0 ${RESOLUTION}x24 -ac +extension GLX +render -noreset </dev/null >"${VNC_LOG_DIR}/xvfb.log" 2>&1 &
sleep 1

x_ready=0
for i in $(seq 1 60); do
  if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
    x_ready=1
    break
  fi
  sleep 1
done
if [ "$x_ready" != "1" ]; then
  echo "Xvfb display ${DISPLAY} did not become ready; xvfb.log:" >&2
  tail -80 "${VNC_LOG_DIR}/xvfb.log" >&2 2>/dev/null || true
fi

start_detached 'openbox.*lxde-rc.xml' "${VNC_LOG_DIR}/openbox.log" /usr/bin/openbox --config-file "${HOME}/.config/openbox/lxde-rc.xml" --replace
# Mark desktop entries trusted before pcmanfm renders them; otherwise LXDE/PCManFM
# may show an "Open With" dialog instead of executing the launcher.
if command -v gio >/dev/null 2>&1; then
  for f in "${HOME}/Desktop/"*.desktop; do
    [ -f "$f" ] || continue
    gio set "$f" metadata::trusted true >/dev/null 2>&1 || dbus-launch gio set "$f" metadata::trusted true >/dev/null 2>&1 || true
  done
fi
pkill -x lxpanel >/dev/null 2>&1 || true
start_detached 'lxpanel.*--profile LXDE' "${VNC_LOG_DIR}/lxpanel.log" /usr/bin/lxpanel --profile LXDE
start_detached 'pcmanfm.*--desktop' "${VNC_LOG_DIR}/pcmanfm.log" /usr/bin/pcmanfm --desktop --profile LXDE

# Start native VNC with a developer-readable auth file. Avoid the base image
# /.password2 and avoid fragile x11vnc flags that can make it exit on older builds.
VNC_AUTH_ARGS="-nopw"
if [ -n "${VNC_PASSWORD:-${PASSWORD:-}}" ] && command -v x11vnc >/dev/null 2>&1; then
  mkdir -p "${HOME}/.vnc"
  x11vnc -storepasswd "${VNC_PASSWORD:-${PASSWORD:-}}" "${HOME}/.vnc/passwd" >/dev/null 2>&1 || true
  chmod 600 "${HOME}/.vnc/passwd" 2>/dev/null || true
  if [ -s "${HOME}/.vnc/passwd" ]; then
    VNC_AUTH_ARGS="-rfbauth ${HOME}/.vnc/passwd"
  fi
fi
pkill -x x11vnc >/dev/null 2>&1 || true
setsid /usr/bin/x11vnc -display ${DISPLAY} -xkb -forever -shared -repeat -listen 0.0.0.0 -rfbport 5900 $VNC_AUTH_ARGS </dev/null >"${VNC_LOG_DIR}/x11vnc.log" 2>&1 &

vnc_ready=0
for i in $(seq 1 60); do
  if python3 - <<'PYVNC'
import socket
s=socket.create_connection(('127.0.0.1', 5900), timeout=1)
b=s.recv(12)
s.close()
raise SystemExit(0 if b.startswith(b'RFB') else 1)
PYVNC
  then
    echo 'native VNC is listening on 5900'
    vnc_ready=1
    break
  fi
  sleep 1
done
if [ "$vnc_ready" != "1" ]; then
  echo 'native VNC did not become ready in start-services; process list:' >&2
  ps aux | grep -E 'Xvfb|x11vnc|websockify|supervisord' | grep -v grep >&2 || true
  echo 'xvfb.log:' >&2
  tail -80 "${VNC_LOG_DIR}/xvfb.log" >&2 2>/dev/null || true
  echo 'x11vnc.log:' >&2
  tail -120 "${VNC_LOG_DIR}/x11vnc.log" >&2 2>/dev/null || true
fi
# Enable VNC/noVNC clipboard sync. x11vnc 0.9.16 rejects its non-portable clipboard flag,
# so keep x11vnc clipboard defaults enabled and bridge X selections with autocutsel.
if command -v autocutsel >/dev/null 2>&1; then
  pkill -x autocutsel >/dev/null 2>&1 || true
  DISPLAY=${DISPLAY} setsid /usr/bin/autocutsel -selection CLIPBOARD -fork </dev/null >"${HOME}/constructor-fabric/autocutsel-clipboard.log" 2>&1 &
  DISPLAY=${DISPLAY} setsid /usr/bin/autocutsel -selection PRIMARY -fork </dev/null >"${HOME}/constructor-fabric/autocutsel-primary.log" 2>&1 &
fi
for i in $(seq 1 40); do
  if ! pgrep -x x11vnc >/dev/null 2>&1; then
    echo 'x11vnc is not running; last log lines:' >&2
    tail -40 "${HOME}/constructor-fabric/x11vnc.log" >&2 2>/dev/null || true
  fi
  if python3 - <<'PYVNC'
import socket
s=socket.create_connection(('127.0.0.1', 5900), timeout=1)
b=s.recv(12)
s.close()
raise SystemExit(0 if b.startswith(b'RFB') else 1)
PYVNC
  then
    echo 'native VNC is listening on 5900'
    break
  fi
  sleep 1
done
# --- Landing page with iframes for codium and trainer ---
if [ -f /etc/nginx/sites-enabled/default ]; then
  sudo rm -f /etc/nginx/sites-enabled/default.bak.*
  # Add health proxy if missing
  sudo python3 <<'PY'
from pathlib import Path
p=Path('/etc/nginx/sites-enabled/default')
if p.exists():
    s = p.read_text()
    import re
    s=re.sub(r'\n\s*auth_basic\s+[^;]+;\s*\n\s*auth_basic_user_file\s+[^;]+;\s*\n', '\n\t# Constructor Fabric: no HTTP basic auth.\n\tauth_basic off;\n', s, count=1)
    if 'location = /health' not in s:
        insert="""
\tlocation = /health {
\t\tauth_basic off;
\t\tproxy_set_header Host $host;
\t\tproxy_set_header X-Real-IP $remote_addr;
\t\tproxy_pass http://127.0.0.1:8081/health;
\t}
"""
        marker='\n\tlocation / {\n'
        if marker in s:
            s=s.replace(marker, insert+marker, 1)
        else:
            s=s.replace('\n}\n', insert+'\n}\n', 1)
    p.write_text(s)
PY
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  LANDING_SRC="${SCRIPT_DIR}/../assets/landing.html"
  if [ -f "$LANDING_SRC" ]; then
    sudo cp "$LANDING_SRC" /usr/local/lib/web/frontend/index.html
  elif [ -f "${HOME}/constructor-fabric/app/landing.html" ]; then
    sudo cp "${HOME}/constructor-fabric/app/landing.html" /usr/local/lib/web/frontend/index.html
  fi
  # Add proxy locations for codium (/ide/) and trainer (/trainer/)
  sudo python3 <<'PY'
from pathlib import Path
p = Path('/etc/nginx/sites-enabled/default')
if p.exists():
    s = p.read_text()
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
  NGINX_BIN="$(command -v nginx || command -v /usr/sbin/nginx || true)"
  if [ -n "$NGINX_BIN" ]; then
    sudo "$NGINX_BIN" -t >"${HOME}/constructor-fabric/nginx-test.log" 2>&1 && (sudo "$NGINX_BIN" -s reload || sudo service nginx reload || true) >"${HOME}/constructor-fabric/nginx-reload.log" 2>&1 || true
  fi
fi
start_detached "${HOME}/constructor-fabric/app/server.py" "${HOME}/constructor-fabric/app.log" python3 "${HOME}/constructor-fabric/app/server.py"
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
  start_detached "codium serve-web" "${HOME}/constructor-fabric/codium-serve.log" \
    "${CODIUM_BIN}" serve-web --port 8080 --host 0.0.0.0 --without-connection-token --server-data-dir "${HOME}/.codium-server"
fi
# --- Trainer HTTP server on port 8082 ---
if [ -d "${HOME}/constructor-fabric/trainer" ]; then
  start_detached "trainer http" "${HOME}/constructor-fabric/trainer-http.log" \
    python3 -m http.server 8082 --directory "${HOME}/constructor-fabric/trainer" --bind 0.0.0.0
fi
if [ -x "${HOME}/cyber-constructor/auto-bootstrap.sh" ]; then
  start_detached "${HOME}/cyber-constructor/auto-bootstrap.sh" "${HOME}/cyber-constructor/auto-bootstrap-launch.log" "${HOME}/cyber-constructor/auto-bootstrap.sh"
fi
if [ -x "${HOME}/constructor-fabric/run-trainer.sh" ]; then
  start_detached 'constructor-fabric/trainer' "${HOME}/constructor-fabric/electron-trainer-launch.log" "${HOME}/constructor-fabric/run-trainer.sh"
fi
