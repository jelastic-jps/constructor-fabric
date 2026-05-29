#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive

export ALSADEV="${ALSADEV:-default}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/tmp/pulse-root}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/tmp/pulse-root/native}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-pulse}"
export AUDIODEV="${AUDIODEV:-default}"

mkdir -p /root/constructor-fabric/app /root/constructor-fabric/data /root/.config/autostart /root/Desktop
SCRIPT_VERSION="${SCRIPT_VERSION:-electron-20260526-1}"
CF_SOURCE_REF="${CF_SOURCE_REF:-main}"
curl --noproxy '*' -fsSL https://files.catbox.moe/3fnged.png -o /root/constructor-fabric/app/icon.png || true
curl --noproxy '*' -fsSL https://files.catbox.moe/pnybix.png -o /root/constructor-fabric/app/wallpaper.png || true
curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/app-server.py?v=${SCRIPT_VERSION}" -o /root/constructor-fabric/app/server.py
chmod +x /root/constructor-fabric/app/server.py

# The focal desktop base can carry a stale Google Chrome apt source whose
# rotated signing key breaks every apt-get update before our packages install.
# Chrome is not required for the JPS bootstrap/noVNC path, so disable only
# that third-party source and keep Ubuntu/Virtuozzo repositories intact.
if [ -f /etc/apt/sources.list.d/google-chrome.list ]; then
  mv /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.list.disabled || true
fi
if [ -f /etc/apt/sources.list.d/google.list ]; then
  mv /etc/apt/sources.list.d/google.list /etc/apt/sources.list.d/google.list.disabled || true
fi

apt-get update
apt-get remove --purge -y firefox firefox-locale-en firefox-esr || true
apt-get install -y --no-install-recommends \
  python3 python3-pip python3-venv curl wget ca-certificates git xdg-utils \
  x11vnc x11-utils net-tools xkb-data openbox lxpanel pcmanfm lxterminal \
  dbus-x11 libnss3 libxss1 libasound2 libgbm1 libgtk-3-0 libsecret-1-0 \
  jq pulseaudio pulseaudio-utils libasound2-plugins alsa-utils autocutsel
if ! command -v google-chrome-stable >/dev/null 2>&1 && ! command -v chromium-browser >/dev/null 2>&1; then
  wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list
  apt-get update || true
  apt-get install -y --no-install-recommends google-chrome-stable || true
fi
apt-get autoremove -y || true
apt-get install -y --reinstall xkb-data

curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/install-cyber-constructor.sh?v=${SCRIPT_VERSION}" -o /root/install-cyber-constructor.sh
chmod +x /root/install-cyber-constructor.sh
/root/install-cyber-constructor.sh

curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/install-ides.sh?v=${SCRIPT_VERSION}" -o /root/constructor-fabric/install-ides.sh
chmod +x /root/constructor-fabric/install-ides.sh
selected_ide_profile="$(printenv CF_IDE_PROFILE || true)"
if [ "$selected_ide_profile" != "cli" ] && [ -n "$selected_ide_profile" ]; then
  # Delay optional heavy IDE package installs until after JPS verify is done.
  # This prevents marketplace cmd[cp] from being killed by signal 9 on small nodes.
  setsid sh -c 'sleep 180; /root/constructor-fabric/install-ides.sh' </dev/null >/root/constructor-fabric/ide-install-wrapper.log 2>&1 &
else
  /root/constructor-fabric/install-ides.sh >/root/constructor-fabric/ide-install-wrapper.log 2>&1 || true
fi

curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/start-services.sh?v=${SCRIPT_VERSION}" -o /root/constructor-fabric/start-services.sh
chmod +x /root/constructor-fabric/start-services.sh
/root/constructor-fabric/start-services.sh
