#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive

export ALSADEV="${ALSADEV:-default}"
export PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-/tmp/pulse-root}"
export PULSE_SERVER="${PULSE_SERVER:-unix:/tmp/pulse-root/native}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-pulse}"
export AUDIODEV="${AUDIODEV:-default}"

# Use ${HOME} for user-specific paths. The base VNC startup script can reset
# /home/developer and /home/developer/constructor-fabric ownership to root at
# container boot, so normalize ownership before writing runtime-downloaded files.
if command -v sudo >/dev/null 2>&1; then
  sudo chown -R "$(id -u):$(id -g)" "${HOME}" 2>/dev/null || true
fi
mkdir -p "${HOME}/constructor-fabric/app" "${HOME}/constructor-fabric/app/icons" "${HOME}/constructor-fabric/assets" "${HOME}/constructor-fabric/data" "${HOME}/.config/autostart" "${HOME}/Desktop"
SCRIPT_VERSION="${SCRIPT_VERSION:-electron-20260526-1}"
CF_SOURCE_REF="${CF_SOURCE_REF:-main}"
ASSET_BASE="https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/assets"
curl --noproxy '*' -fsSL "${ASSET_BASE}/constructor-fabric-logo.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/icon.png" || true
curl --noproxy '*' -fsSL "${ASSET_BASE}/constructor-fabric-wallpaper.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/wallpaper.png" || true
curl --noproxy '*' -fsSL "${ASSET_BASE}/vscode-logo.png?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/assets/vscode-logo.png" || true
if [ -s "${HOME}/constructor-fabric/assets/vscode-logo.png" ]; then
  cp "${HOME}/constructor-fabric/assets/vscode-logo.png" "${HOME}/constructor-fabric/app/icons/codium.png" 2>/dev/null || true
fi
curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/app-server.py?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/app/server.py"
chmod +x "${HOME}/constructor-fabric/app/server.py"

# NOTE: System-level package installation (apt-get, etc.) is done during Docker build
# This bootstrap script only handles user-level operations

# Install cyber-constructor under developer home
curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/install-cyber-constructor.sh?v=${SCRIPT_VERSION}" -o "${HOME}/install-cyber-constructor.sh"
chmod +x "${HOME}/install-cyber-constructor.sh"
"${HOME}/install-cyber-constructor.sh"

# Install IDEs under developer home
curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/install-ides.sh?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/install-ides.sh"
chmod +x "${HOME}/constructor-fabric/install-ides.sh"
selected_ide_profile="$(printenv CF_IDE_PROFILE || true)"
# Always normalize the visible desktop immediately. Some prebuilt images contain stale
# launchers (for example Chromium-Browser.desktop or terminal-only Codex/Claude
# shortcuts). The CLI profile only recreates the clean GUI launchers from binaries
# already present, so it is safe and quick before JPS verify.
CF_IDE_PROFILE=cli "${HOME}/constructor-fabric/install-ides.sh" >"${HOME}/constructor-fabric/ide-install-wrapper.log" 2>&1 || true
if [ -s "${HOME}/constructor-fabric/assets/vscode-logo.png" ]; then
  cp "${HOME}/constructor-fabric/assets/vscode-logo.png" "${HOME}/constructor-fabric/app/icons/codium.png" 2>/dev/null || true
fi
if [ "$selected_ide_profile" != "cli" ] && [ -n "$selected_ide_profile" ]; then
  # Delay optional heavy IDE package installs until after JPS verify is done.
  # This prevents marketplace cmd[cp] from being killed by signal 9 on small nodes.
  setsid sh -c "sleep 180; ${HOME}/constructor-fabric/install-ides.sh" </dev/null >>"${HOME}/constructor-fabric/ide-install-wrapper.log" 2>&1 &
fi

# Start services under developer home
curl --noproxy '*' -fsSL "https://raw.githubusercontent.com/jelastic-jps/constructor-fabric/${CF_SOURCE_REF}/scripts/start-services.sh?v=${SCRIPT_VERSION}" -o "${HOME}/constructor-fabric/start-services.sh"
chmod +x "${HOME}/constructor-fabric/start-services.sh"
"${HOME}/constructor-fabric/start-services.sh"
