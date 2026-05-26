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
      curl wget ca-certificates git xdg-utils \
      x11vnc x11-utils net-tools xkb-data \
      openbox lxpanel pcmanfm lxterminal dbus-x11 \
      libnss3 libxss1 libasound2 libgbm1 libgtk-3-0 libsecret-1-0 \
      jq pulseaudio pulseaudio-utils nodejs npm \
      xauth xvfb \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/node-current/bin \
    && ln -sf /usr/bin/node /opt/node-current/bin/node \
    && ln -sf /usr/bin/npm /opt/node-current/bin/npm

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
RUN chmod +x /root/constructor-fabric/scripts/*.sh 2>/dev/null || true

WORKDIR /root/constructor-fabric
