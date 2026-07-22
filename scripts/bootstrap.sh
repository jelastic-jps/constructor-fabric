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

curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${ASSET_BASE}/constructor-fabric-logo.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/icon.png" || true
curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${ASSET_BASE}/constructor-fabric-wallpaper.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/wallpaper.png" || true
# Refresh the Trainer (extension + ui + content) from the repo; the image
# already ships a baked copy, so failed downloads fall back to it.
TRAINER_FILES="extension/package.json extension/extension.js ui/index.html ui/trainer.js ui/trainer.css content/curriculum.json content/brief.md"
for f in $TRAINER_FILES; do
  mkdir -p "${HOME}/constructor-fabric/trainer/$(dirname "$f")"
  curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${TRAINER_BASE}/${f}?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/trainer/${f}" || true
done
rm -f "${HOME}/constructor-fabric/trainer/index.html" "${HOME}/constructor-fabric/trainer/main.js" "${HOME}/constructor-fabric/trainer/package.json"

curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${SCRIPT_BASE}/install-constructor-studio.sh?v=${SCRIPT_VERSION}" -o "${HOME}/install-constructor-studio.sh"
chmod +x "${HOME}/install-constructor-studio.sh"
"${HOME}/install-constructor-studio.sh"

# Place the workspace auto-bootstrap script (single source: scripts/auto-bootstrap.sh);
# fall back to the copy baked into the image if the download fails.
curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${SCRIPT_BASE}/auto-bootstrap.sh?v=${SCRIPT_VERSION}" -o "${HOME}/studio/auto-bootstrap.sh" \
  || cp "${HOME}/constructor-fabric/scripts/auto-bootstrap.sh" "${HOME}/studio/auto-bootstrap.sh"
chmod +x "${HOME}/studio/auto-bootstrap.sh"

curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${SCRIPT_BASE}/install-coding-agent.sh?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/install-coding-agent.sh" \
  || cp "${HOME}/constructor-fabric/scripts/install-coding-agent.sh" "${HOME}/constructor-fabric/install-coding-agent.sh"
chmod +x "${HOME}/constructor-fabric/install-coding-agent.sh"

curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "${SCRIPT_BASE}/start-services.sh?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/start-services.sh"
chmod +x "${HOME}/constructor-fabric/start-services.sh"
"${HOME}/constructor-fabric/start-services.sh"
