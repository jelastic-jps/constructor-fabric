#!/bin/sh
set -eu
export DISPLAY=:1
export HOME=/root
export USER=root
export XDG_CURRENT_DESKTOP=LXDE
export DESKTOP_SESSION=LXDE
mkdir -p /tmp/.X11-unix /root/constructor-fabric /root/.config/pcmanfm/LXDE /root/.config/lxpanel/LXDE/panels /root/.config/libfm
chmod 1777 /tmp/.X11-unix || true
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
mkdir -p /dev/snd /tmp/pulse-root /root/.config/pulse
chmod 755 /dev/snd || true
chmod 700 /tmp/pulse-root || true
cat > /root/.config/pulse/client.conf <<'PULSECLIENT'
default-server = unix:/tmp/pulse-root/native
autospawn = yes
daemon-binary = /usr/bin/pulseaudio
PULSECLIENT
cat > /root/.asoundrc <<'ASOUNDRC'
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
cp /root/.asoundrc /etc/asound.conf 2>/dev/null || true
if command -v pulseaudio >/dev/null 2>&1; then
  pulseaudio --kill >/dev/null 2>&1 || true
  pulseaudio --daemonize=yes --exit-idle-time=-1 --disallow-exit --log-target=file:/root/constructor-fabric/pulseaudio.log || true
  if command -v pactl >/dev/null 2>&1; then
    for i in $(seq 1 20); do pactl info >/dev/null 2>&1 && break || sleep 0.2; done
    pactl load-module module-null-sink sink_name=virt_audio sink_properties=device.description=VirtualAudio >/dev/null 2>&1 || true
    pactl set-default-sink virt_audio >/dev/null 2>&1 || true
    pactl set-default-source virt_audio.monitor >/dev/null 2>&1 || true
  fi
fi
cat > /root/.config/libfm/libfm.conf <<'LIBFM'
[config]
quick_exec=1
single_click=0
middle_click=0
LIBFM
if [ -f /root/constructor-fabric/app/wallpaper.png ]; then
  cat > /root/.config/pcmanfm/LXDE/desktop-items-0.conf <<'WALLCONF'
[*]
wallpaper_mode=fit
wallpaper=/root/constructor-fabric/app/wallpaper.png
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
  python3 - <<'PYCONF'
from pathlib import Path
p = Path('/etc/supervisor/conf.d/supervisord.conf')
text = p.read_text()
text = text.replace('command=x11vnc -display :1 -xkb -forever -shared -repeat -rfbauth /.password2', 'command=x11vnc -display :1 -xkb -forever -shared -repeat -noxfixes -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -rfbauth /.password2 -clipboard')
p.write_text(text)
PYCONF
fi

configure_openbox_theme() {
  mkdir -p /usr/share/themes/ConstructorFabric/openbox-3 /root/.config/openbox /root/.config/gtk-3.0 /root/.config/gtk-2.0
  cat > /usr/share/themes/ConstructorFabric/openbox-3/themerc <<'OBTHEME'
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
  cat > /usr/share/themes/ConstructorFabric/openbox-3/close.xbm <<'OBXBM'
#define close_width 8
#define close_height 8
static unsigned char close_bits[] = { 0xc3,0xe7,0x7e,0x3c,0x3c,0x7e,0xe7,0xc3 };
OBXBM
  cat > /usr/share/themes/ConstructorFabric/openbox-3/max.xbm <<'OBXBM'
#define max_width 8
#define max_height 8
static unsigned char max_bits[] = { 0xff,0x81,0x81,0x81,0x81,0x81,0x81,0xff };
OBXBM
  cat > /usr/share/themes/ConstructorFabric/openbox-3/iconify.xbm <<'OBXBM'
#define iconify_width 8
#define iconify_height 8
static unsigned char iconify_bits[] = { 0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff };
OBXBM
  cat > /usr/share/themes/ConstructorFabric/openbox-3/shade.xbm <<'OBXBM'
#define shade_width 8
#define shade_height 8
static unsigned char shade_bits[] = { 0x18,0x3c,0x7e,0xff,0x00,0x00,0x00,0x00 };
OBXBM
  cat > /usr/share/themes/ConstructorFabric/openbox-3/desk.xbm <<'OBXBM'
#define desk_width 8
#define desk_height 8
static unsigned char desk_bits[] = { 0xff,0x81,0xbd,0xa5,0xa5,0xbd,0x81,0xff };
OBXBM
  for n in close max iconify shade desk; do
    cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_pressed.xbm"
    cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_hover.xbm"
    cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_disabled.xbm"
  done
  python3 - <<'PYOB'
from pathlib import Path
candidates = [
  Path('/etc/xdg/openbox/LXDE/rc.xml'),
  Path('/etc/xdg/openbox/rc.xml'),
  Path('/usr/share/openbox/rc.xml'),
  Path('/usr/share/lxde/openbox/rc.xml'),
]
p=Path('/root/.config/openbox/lxde-rc.xml')
for src in candidates:
  if src.exists():
    p.write_text(src.read_text())
    break
else:
  p.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<openbox_config xmlns="http://openbox.org/3.4/rc"><theme><name>Onyx</name></theme><font><name>Sans</name><size>11</size></font></openbox_config>\n')
s=p.read_text().replace('<name>Onyx</name>', '<name>ConstructorFabric</name>').replace('<size>11</size>', '<size>12</size>')
p.write_text(s)
PYOB
  cat > /root/.config/gtk-3.0/settings.ini <<'GTK3'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 11
GTK3
  cat > /root/.gtkrc-2.0 <<'GTK2'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Adwaita"
gtk-font-name="Sans 11"
GTK2
}

configure_lxpanel() {
  mkdir -p /root/.config/lxpanel/LXDE/panels
  cat > /root/.config/lxpanel/LXDE/panels/panel <<'LXPANEL'
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
    image=/root/constructor-fabric/app/icon.png
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
      command=lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace
    }
    item {
      name=Workspace
      image=folder
      command=pcmanfm /root/workspaces/constructor-fabric-workspace
    }
  }
}
Plugin {
  type=launchbar
  Config {
    Button {
      id=/root/Desktop/Constructor-Fabric-Trainer.desktop
    }
    Button {
      id=/root/Desktop/VS-Code.desktop
    }
    Button {
      id=/root/Desktop/Cursor.desktop
    }
    Button {
      id=/root/Desktop/Windsurf.desktop
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
  cat > /root/.config/lxpanel/LXDE/config <<'LXCONF'
[Command]
FileManager=pcmanfm %s
Terminal=lxterminal
Logout=lxsession-logout
LXCONF
}

configure_openbox_theme
configure_lxpanel
start_detached 'Xvfb :1' /root/constructor-fabric/xvfb.log /usr/bin/Xvfb :1 -screen 0 ${RESOLUTION}x24 -ac +extension GLX +render -noreset
sleep 3
start_detached 'openbox.*lxde-rc.xml' /root/constructor-fabric/openbox.log /usr/bin/openbox --config-file /root/.config/openbox/lxde-rc.xml --replace
pkill -x lxpanel >/dev/null 2>&1 || true
start_detached 'lxpanel.*--profile LXDE' /root/constructor-fabric/lxpanel.log /usr/bin/lxpanel --profile LXDE
start_detached 'pcmanfm.*--desktop' /root/constructor-fabric/pcmanfm.log /usr/bin/pcmanfm --desktop --profile LXDE
# Avoid a foreground wallpaper setter here: on dorowu/LXDE it can stay attached
# and the Virtuozzo Cloud Scripting engine can eventually kill the whole cmd action with signal 9.
# The desktop-items-0.conf written above is enough for pcmanfm to pick the wallpaper.
pkill -x x11vnc >/dev/null 2>&1 || true
sleep 1
if [ -s /.password2 ]; then
  start_detached 'x11vnc.*rfbport 5900' /root/constructor-fabric/x11vnc.log /usr/bin/x11vnc -display :1 -xkb -forever -shared -repeat -noxfixes -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -rfbauth /.password2 -clipboard
else
  start_detached 'x11vnc.*rfbport 5900' /root/constructor-fabric/x11vnc.log /usr/bin/x11vnc -display :1 -xkb -forever -shared -repeat -noxfixes -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -nopw -clipboard
fi
# Enable VNC clipboard bidirectional sync via autocutsel
if command -v autocutsel >/dev/null 2>&1; then
  start_detached 'autocutsel' /root/constructor-fabric/autocutsel.log /usr/bin/autocutsel -fork
fi
# Bypass the base image's Vue noVNC wrapper: it can throw
# `Vnc.vue:120 TypeError: this.$t is not a function` in some browsers.
# Serve a tiny redirector to the upstream noVNC page directly, with the
# generated VNC password and websocket path filled in.
if [ -d /usr/local/lib/web/frontend ]; then
  cat > /usr/local/lib/web/frontend/index.html <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Constructor Fabric noVNC</title>
<style>html,body{margin:0;width:100%;height:100%;background:#050505;color:#eee;font-family:system-ui,sans-serif}.msg{padding:24px}</style></head>
<body><div class="msg">Opening Constructor Fabric noVNC...</div><script>
(function(){
  var host = window.location.hostname;
  var port = window.location.port || (window.location.protocol === 'https:' ? '443' : '80');
  var pass = window.__VNC_PASSWORD__ || '';
  var qs = new URLSearchParams({host: host, port: port, path: 'websockify', autoconnect: 'true', resize: 'remote'});
  if (pass) qs.set('password', pass);
  window.location.replace('/static/novnc/vnc.html?' + qs.toString());
})();
</script></body></html>
HTML
  python3 - <<'PY'
from pathlib import Path
import os
p=Path('/usr/local/lib/web/frontend/index.html')
s=p.read_text()
passwd=os.environ.get('VNC_PASSWORD') or os.environ.get('PASSWORD') or ''
s=s.replace("window.__VNC_PASSWORD__ || ''", repr(passwd))
p.write_text(s)
PY
fi
if [ -f /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default.bak.*
  python3 - <<'PY'
from pathlib import Path
p=Path('/etc/nginx/sites-enabled/default')
s=p.read_text()
import re
s=re.sub(r'\n\s*auth_basic\s+[^;]+;\s*\n\s*auth_basic_user_file\s+[^;]+;\s*\n', '\n\t# Constructor Fabric: no HTTP basic auth; VNC itself is password-protected.\n\tauth_basic off;\n', s, count=1)
if 'location /websockify' not in s:
    ws="""
\tlocation /websockify {
\t\tproxy_connect_timeout 7d;
\t\tproxy_send_timeout 7d;
\t\tproxy_read_timeout 7d;
\t\tproxy_buffering off;
\t\tproxy_http_version 1.1;
\t\tproxy_set_header Upgrade $http_upgrade;
\t\tproxy_set_header Connection "upgrade";
\t\tproxy_set_header Host $host;
\t\tproxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
\t\tproxy_pass http://127.0.0.1:6081;
\t}
"""
    marker='\n\tlocation ~ .*/(api/.*|websockify) {\n'
    if marker in s:
        s=s.replace(marker, ws+marker, 1)
    else:
        s=s.replace('\n\tlocation / {\n', ws+'\n\tlocation / {\n', 1)
if 'location = /health' not in s:
    insert="""
	location = /health {
		auth_basic off;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_pass http://127.0.0.1:8081/health;
	}
"""
    marker='\n\tlocation / {\n'
    if marker in s:
        s=s.replace(marker, insert+marker, 1)
    else:
        s=s.replace('\n}\n', insert+'\n}\n', 1)
p.write_text(s)
PY
  NGINX_BIN="$(command -v nginx || command -v /usr/sbin/nginx || true)"
  if [ -n "$NGINX_BIN" ]; then
    "$NGINX_BIN" -t >/root/constructor-fabric/nginx-test.log 2>&1 && ("$NGINX_BIN" -s reload || service nginx reload || true) >/root/constructor-fabric/nginx-reload.log 2>&1 || true
  fi
fi
start_detached '/root/constructor-fabric/app/server.py' /root/constructor-fabric/app.log python3 /root/constructor-fabric/app/server.py
if [ -x /root/cyber-constructor/auto-bootstrap.sh ]; then
  start_detached '/root/cyber-constructor/auto-bootstrap.sh' /root/cyber-constructor/auto-bootstrap-launch.log /root/cyber-constructor/auto-bootstrap.sh
fi
if [ -x /root/constructor-fabric/run-trainer.sh ]; then
  start_detached 'constructor-fabric/trainer' /root/constructor-fabric/electron-trainer-launch.log /root/constructor-fabric/run-trainer.sh
fi
