#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive

# User-level bootstrap only. The image already contains system packages.
export HOME="${HOME:-/home/developer}"
SCRIPT_VERSION="${SCRIPT_VERSION:-code-server-current-20260707-1}"
CF_SOURCE_REF="${CF_SOURCE_REF:-main}"
ASSET_BASE="https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/assets"
TRAINER_BASE="https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/trainer"
SCRIPT_BASE="https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts"

mkdir -p "${HOME}/constructor-fabric/app" "${HOME}/constructor-fabric/data" "${HOME}/constructor-fabric/trainer" "${HOME}/workspaces/constructor-fabric-workspace"

curl --noproxy '*' -fsSL "${ASSET_BASE}/constructor-fabric-logo.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/icon.png" || true
curl --noproxy '*' -fsSL "${ASSET_BASE}/constructor-fabric-wallpaper.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/wallpaper.png" || true
curl --noproxy '*' -fsSL "${TRAINER_BASE}/index.html?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/trainer/index.html" || true
curl --noproxy '*' -fsSL "${TRAINER_BASE}/main.js?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/trainer/main.js" || true
curl --noproxy '*' -fsSL "${TRAINER_BASE}/package.json?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/trainer/package.json" || true

curl --noproxy '*' -fsSL "${SCRIPT_BASE}/install-constructor-studio.sh?v=${SCRIPT_VERSION}" -o "${HOME}/install-constructor-studio.sh"
chmod +x "${HOME}/install-constructor-studio.sh"
"${HOME}/install-constructor-studio.sh"

curl --noproxy '*' -fsSL "${SCRIPT_BASE}/start-services.sh?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/start-services.sh"
chmod +x "${HOME}/constructor-fabric/start-services.sh"
"${HOME}/constructor-fabric/start-services.sh"
