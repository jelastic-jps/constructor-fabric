FROM ubuntu:focal

ARG DEBIAN_FRONTEND=noninteractive
ARG UV_INSTALL_DIR=/home/developer/.local/bin
ARG CYBER_CONSTRUCTOR_TARBALL_URL=https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/main/assets/cyber-constructor-v4.0.0.tar.gz
ARG CYBER_CONSTRUCTOR_TARBALL_SHA256=8ca1c8005097cb3bdca521888a61cc3f0c508601a199722d2585e3130703a626

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV TZ=Europe/Kyiv \
    HOME=/home/developer \
    USER=developer \
    PATH=/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg xz-utils sudo passwd \
      python3 python3-pip python3-venv \
      supervisor jq net-tools procps psmisc \
    && rm -rf /var/lib/apt/lists/*

RUN /usr/sbin/useradd -m -u 1000 -s /bin/bash developer \
    && printf '%s\n' 'developer ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/developer \
    && chmod 0440 /etc/sudoers.d/developer


RUN mkdir -p /opt \
    && curl --noproxy '*' -fsSL https://nodejs.org/dist/v22.16.0/node-v22.16.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && rm -rf /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && tar -xJf /tmp/node.tar.xz -C /opt \
    && ln -s /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && ln -sf /opt/node-current/bin/node /usr/local/bin/node \
    && ln -sf /opt/node-current/bin/npm /usr/local/bin/npm \
    && ln -sf /opt/node-current/bin/npx /usr/local/bin/npx \
    && rm -f /tmp/node.tar.xz

ARG CODE_SERVER_VERSION=4.127.0
RUN curl --noproxy '*' -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-amd64.tar.gz" \
      | tar -xz --strip-components=1 -C /usr/local \
    && code-server --version

RUN mkdir -p /home/developer/.local/bin \
    && wget -q https://astral.sh/uv/install.sh -O /tmp/install-uv.sh \
    && sh /tmp/install-uv.sh \
    && rm -f /tmp/install-uv.sh \
    && chown -R developer:developer /home/developer/.local

RUN mkdir -p /home/developer/cfc-build /home/developer/cyber-constructor /home/developer/.cf-constructor/cache \
    && cd /home/developer/cfc-build \
    && curl --noproxy '*' -fsSL "${CYBER_CONSTRUCTOR_TARBALL_URL}" -o cyber-constructor.tar.gz \
    && echo "${CYBER_CONSTRUCTOR_TARBALL_SHA256}  cyber-constructor.tar.gz" | sha256sum -c - \
    && tar -xzf cyber-constructor.tar.gz -C /home/developer/cyber-constructor \
    && find /home/developer/cyber-constructor \( -name '._*' -o -name '.DS_Store' \) -delete \
    && cp -a /home/developer/cyber-constructor/skills /home/developer/.cf-constructor/cache/ \
    && if [ -d /home/developer/cyber-constructor/config ]; then cp -a /home/developer/cyber-constructor/config /home/developer/.cf-constructor/cache/; fi \
    && echo v4.0.0 > /home/developer/.cf-constructor/cache/.version \
    && rm -rf /home/developer/cfc-build \
    && chown -R developer:developer /home/developer/cyber-constructor /home/developer/.cf-constructor

COPY . /home/developer/constructor-fabric/
RUN chmod +x /home/developer/constructor-fabric/scripts/*.sh 2>/dev/null || true \
    && mkdir -p /home/developer/workspaces/constructor-fabric-workspace /home/developer/constructor-fabric/data \
    && /home/developer/.local/bin/uv python install 3.11 \
    && /home/developer/.local/bin/uv venv --python 3.11 /home/developer/cyber-constructor/.venv \
    && /home/developer/.local/bin/uv pip install --python /home/developer/cyber-constructor/.venv/bin/python -e /home/developer/cyber-constructor \
    && ln -sf /home/developer/cyber-constructor/.venv/bin/cfc /usr/local/bin/cfc \
    && ln -sf /home/developer/cyber-constructor/.venv/bin/cf-constructor /usr/local/bin/cf-constructor \
    && printf 'd\n' | /usr/local/bin/cfc init --no-cache --project-root /home/developer/workspaces/constructor-fabric-workspace --install-dir .cf-constructor --project-name "constructor-fabric-workspace" --force \
    && /usr/local/bin/cfc generate-agents --root /home/developer/workspaces/constructor-fabric-workspace -y \
    && cp -f /home/developer/constructor-fabric/trainer/index.html /home/developer/workspaces/constructor-fabric-workspace/.trainer-welcome.html 2>/dev/null || true \
    && chown -R developer:developer /home/developer

WORKDIR /home/developer/workspaces/constructor-fabric-workspace

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["sleep", "infinity"]
