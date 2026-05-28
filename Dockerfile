FROM dorowu/ubuntu-desktop-lxde-vnc:focal

ARG DEBIAN_FRONTEND=noninteractive
ARG UV_INSTALL_DIR=/root/.local/bin
ARG CYBER_CONSTRUCTOR_TARBALL_URL=https://files.catbox.moe/qb6e6d.gz
ARG CYBER_CONSTRUCTOR_TARBALL_SHA256=8ca1c8005097cb3bdca521888a61cc3f0c508601a199722d2585e3130703a626

ENV TZ=Europe/Kyiv \
    HOME=/root \
    USER=root \
    PATH=/opt/node-current/bin:/root/.local/bin:/usr/local/bin:/usr/bin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      curl wget ca-certificates git xdg-utils gnupg apt-transport-https xz-utils \
      x11vnc x11-utils net-tools xkb-data \
      openbox lxpanel pcmanfm lxterminal dbus-x11 \
      libnss3 libxss1 libasound2 libgbm1 libgtk-3-0 libsecret-1-0 libfuse2 \
      libxshmfence1 libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxrandr2 libxkbcommon0 \
      jq pulseaudio pulseaudio-utils libasound2-plugins alsa-utils nodejs npm \
      xauth xvfb autocutsel fonts-liberation libu2f-udev \
    && apt-get remove --purge -y firefox firefox-locale-en || true \
    && apt-get autoremove -y || true \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome and set as default browser (Chromium snap fails in Docker)
RUN wget -qO- https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /usr/share/keyrings/google-chrome.gpg \
    && echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/* \
    && xdg-settings set default-web-browser google-chrome.desktop || true \
    && update-alternatives --set x-www-browser /usr/bin/google-chrome-stable 2>/dev/null || true

# Enable VNC clipboard via x11vnc + autocutsel
COPY patch-x11vnc.py /tmp/patch-x11vnc.py
RUN python3 /tmp/patch-x11vnc.py && rm /tmp/patch-x11vnc.py

RUN mkdir -p /opt \
    && curl --noproxy '*' -fsSL https://nodejs.org/dist/v22.16.0/node-v22.16.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && rm -rf /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && tar -xJf /tmp/node.tar.xz -C /opt \
    && ln -s /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && ln -sf /opt/node-current/bin/node /usr/local/bin/node \
    && ln -sf /opt/node-current/bin/npm /usr/local/bin/npm \
    && ln -sf /opt/node-current/bin/npx /usr/local/bin/npx \
    && rm -f /tmp/node.tar.xz \
    && /opt/node-current/bin/npm install -g electron@latest

RUN mkdir -p /root/.local/bin \
    && wget -q https://astral.sh/uv/install.sh -O /tmp/install-uv.sh \
    && sh /tmp/install-uv.sh \
    && rm -f /tmp/install-uv.sh

RUN mkdir -p /root/cfc-build /root/cyber-constructor /root/.cf-constructor/cache \
    && cd /root/cfc-build \
    && curl --noproxy '*' -fsSL "${CYBER_CONSTRUCTOR_TARBALL_URL}" -o cyber-constructor.tar.gz \
    && echo "${CYBER_CONSTRUCTOR_TARBALL_SHA256}  cyber-constructor.tar.gz" | sha256sum -c - \
    && tar -xzf cyber-constructor.tar.gz -C /root/cyber-constructor \
    && find /root/cyber-constructor \( -name '._*' -o -name '.DS_Store' \) -delete \
    && cp -a /root/cyber-constructor/skills /root/.cf-constructor/cache/ \
    && if [ -d /root/cyber-constructor/config ]; then cp -a /root/cyber-constructor/config /root/.cf-constructor/cache/; fi \
    && echo v4.0.0 > /root/.cf-constructor/cache/.version \
    && rm -rf /root/cfc-build

RUN mkdir -p /root/constructor-fabric/app /root/constructor-fabric/data /root/.config/autostart /root/Desktop /root/.config/lxpanel/LXDE/panels /root/.config/libfm /root/.config/pcmanfm/LXDE /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix || true

# Pre-download edited wallpaper (without Powered by Virtuozzo on right)
RUN mkdir -p /root/constructor-fabric/app \
    && curl --noproxy '*' -fsSL https://files.catbox.moe/pnybix.png -o /root/constructor-fabric/app/wallpaper.png

ENV ALSADEV=default \
    PULSE_RUNTIME_PATH=/tmp/pulse-root \
    PULSE_SERVER=unix:/tmp/pulse-root/native \
    SDL_AUDIODRIVER=pulse \
    AUDIODEV=default

COPY . /root/constructor-fabric/
RUN chmod +x /root/constructor-fabric/scripts/*.sh 2>/dev/null || true \
    && CF_IDE_PROFILE=all CF_PREINSTALLED_IDES=0 /root/constructor-fabric/scripts/install-ides.sh \
    && command -v code \
    && command -v cursor \
    && command -v windsurf \
    && command -v codex \
    && command -v claude \
    && echo 'Constructor Fabric IDEs and agent CLIs are preinstalled'

# Install Chromium browser and create desktop icons
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends chromium-browser || \
    echo "Chromium skipped (Google Chrome available)"; \
    rm -rf /var/lib/apt/lists/*

# Desktop icons for Chromium/Chrome and Terminal
RUN python3 - <<'PY'
from pathlib import Path
d = Path('/root/Desktop')
d.mkdir(parents=True, exist_ok=True)

chrome = d / 'Chromium-Browser.desktop'
chrome_bin = '/usr/bin/chromium-browser'
chrome_name = 'Chromium'
if not Path(chrome_bin).exists():
    chrome_bin = '/usr/bin/google-chrome-stable'
    chrome_name = 'Google Chrome'
chrome.write_text(f'''[Desktop Entry]
Version=1.0
Type=Application
Name={chrome_name}
Exec={chrome_bin} --no-sandbox --disable-gpu %U
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
''')
chrome.chmod(0o755)

term = d / 'Terminal.desktop'
term.write_text('''[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open a terminal emulator
Exec=lxterminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
''')
term.chmod(0o755)
print(f'Created desktop icons: {chrome_name}, Terminal')
PY

ENV CF_PREINSTALLED_IDES=1

WORKDIR /root/constructor-fabric
