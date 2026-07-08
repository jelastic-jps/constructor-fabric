FROM ubuntu:focal

ARG DEBIAN_FRONTEND=noninteractive
ARG UV_INSTALL_DIR=/home/developer/.local/bin
ARG STUDIO_REPO=constructorfabric/studio
# "latest" resolves to the newest published release at build time;
# pass --build-arg STUDIO_VERSION=vX.Y.Z to pin a specific release.
ARG STUDIO_VERSION=latest

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

# Resolve the latest published Constructor Studio release tag via the
# /releases/latest redirect, then bake its source into the image. The resolved
# version is recorded in the skill cache .version file, which the install
# layer below reads for setuptools-scm.
RUN mkdir -p /home/developer/studio-build /home/developer/studio /home/developer/.cf-studio/cache \
    && cd /home/developer/studio-build \
    && if [ "${STUDIO_VERSION}" = "latest" ]; then \
         STUDIO_VERSION="$(curl --noproxy '*' -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${STUDIO_REPO}/releases/latest" | sed 's|.*/tag/||')"; \
       fi \
    && case "${STUDIO_VERSION}" in v[0-9]*) ;; *) echo "Failed to resolve Constructor Studio release (got: '${STUDIO_VERSION}')" >&2; exit 1;; esac \
    && echo "Baking Constructor Studio ${STUDIO_VERSION}" \
    && curl --noproxy '*' -fsSL "https://github.com/${STUDIO_REPO}/archive/refs/tags/${STUDIO_VERSION}.tar.gz" -o studio.tar.gz \
    && tar -xzf studio.tar.gz --strip-components=1 -C /home/developer/studio \
    && find /home/developer/studio \( -name '._*' -o -name '.DS_Store' \) -delete \
    && cp -a /home/developer/studio/skills /home/developer/.cf-studio/cache/ \
    && if [ -d /home/developer/studio/config ]; then cp -a /home/developer/studio/config /home/developer/.cf-studio/cache/; fi \
    && echo "${STUDIO_VERSION}" > /home/developer/.cf-studio/cache/.version \
    && rm -rf /home/developer/studio-build \
    && chown -R developer:developer /home/developer/studio /home/developer/.cf-studio

COPY . /home/developer/constructor-fabric/
RUN chmod +x /home/developer/constructor-fabric/scripts/*.sh 2>/dev/null || true \
    && mkdir -p /home/developer/workspaces/constructor-fabric-workspace /home/developer/constructor-fabric/data \
    && /home/developer/.local/bin/uv python install 3.11 \
    && /home/developer/.local/bin/uv venv --python 3.11 /home/developer/studio/.venv \
# Studio derives its package version from git metadata (setuptools-scm); the
# release tarball has none, so pass the version resolved by the layer above.
    && SETUPTOOLS_SCM_PRETEND_VERSION="$(sed 's/^v//' /home/developer/.cf-studio/cache/.version)" \
       /home/developer/.local/bin/uv pip install --python /home/developer/studio/.venv/bin/python -e /home/developer/studio \
    && ln -sf /home/developer/studio/.venv/bin/cfs /usr/local/bin/cfs \
    && ln -sf /home/developer/studio/.venv/bin/constructor-studio /usr/local/bin/constructor-studio \
    && /usr/local/bin/cfs init --no-cache --project-root /home/developer/workspaces/constructor-fabric-workspace --install-dir .cf-studio --project-name "constructor-fabric-workspace" --force --yes \
    && /usr/local/bin/cfs generate-agents --root /home/developer/workspaces/constructor-fabric-workspace -y \
    && cp -f /home/developer/constructor-fabric/trainer/index.html /home/developer/workspaces/constructor-fabric-workspace/.trainer-welcome.html 2>/dev/null || true \
    && chown -R developer:developer /home/developer

WORKDIR /home/developer/workspaces/constructor-fabric-workspace

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["sleep", "infinity"]
