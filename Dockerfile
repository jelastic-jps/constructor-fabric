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
      xauth xvfb \
    && rm -rf /var/lib/apt/lists/*

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

COPY . /root/constructor-fabric/
RUN chmod +x /root/constructor-fabric/scripts/*.sh 2>/dev/null || true \
    && CF_IDE_PROFILE=all CF_PREINSTALLED_IDES=0 /root/constructor-fabric/scripts/install-ides.sh \
    && command -v code \
    && command -v cursor \
    && command -v windsurf \
    && command -v codex \
    && command -v claude \
    && echo 'Constructor Fabric IDEs and agent CLIs are preinstalled'

ENV CF_PREINSTALLED_IDES=1

WORKDIR /root/constructor-fabric
