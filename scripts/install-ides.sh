#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive
export HOME="${HOME:-/home/developer}"
export DISPLAY=:1
export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH
PROFILE="$(printenv CF_IDE_PROFILE || true)"
if [ -z "$PROFILE" ]; then PROFILE=cli; fi
LOG="${HOME}/constructor-fabric/ide-install.log"
mkdir -p "${HOME}/constructor-fabric" "${HOME}/Desktop" "${HOME}/Downloads"
sudo mkdir -p /opt
echo "Constructor Fabric IDE automation profile: $PROFILE" > "$LOG"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
mkdir -p "${HOME}/constructor-fabric/app/icons"

# Keep the visible desktop clean and useful: no fake letter icons and no terminal-only
# agent shortcuts. Claude/Codex integrations are generated for the IDEs, but the
# desktop must launch real GUI IDEs plus the trainer.
clean_desktop_launchers(){
  mkdir -p "${HOME}/Desktop"
  rm -f "${HOME}/Desktop/"*.desktop 2>/dev/null || true
}

# Create a simple PNG icon (1x1 pixel)
create_placeholder_icon(){
  target_path="$1"
  # Create a minimal 1x1 pixel PNG as placeholder (base64 encoded)
  echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" | base64 -d > "$target_path" 2>/dev/null || true
}

# Ensure icon exists at a guaranteed path
ensure_icon(){
  icon_name="$1"
  target_path="$2"
  
  # If a real icon already exists at target, return success. Tiny 1x1 PNGs
  # are old placeholders and must be replaced with the real app icons.
  if [ -f "$target_path" ] && [ "$(wc -c < "$target_path" 2>/dev/null || echo 0)" -gt 1024 ]; then
    return 0
  fi
  
  # Try to find and copy the icon from system locations
  case "$icon_name" in
    codium|vscode|vscodium)
      for src in "${HOME}/constructor-fabric/assets/vscode-logo.png" /usr/share/pixmaps/code.png /usr/share/icons/hicolor/256x256/apps/code.png /usr/share/pixmaps/codium.png /usr/share/icons/hicolor/256x256/apps/codium.png /usr/share/icons/hicolor/256x256/apps/vscodium.png; do
        if [ -f "$src" ]; then
          cp "$src" "$target_path" 2>/dev/null && return 0
        fi
      done
      # Use the VS Code icon for VS Codium as requested. The old VSCodium URL is 404.
      curl --noproxy "*" -fsSL https://raw.githubusercontent.com/microsoft/vscode/main/resources/linux/code.png -o "$target_path" 2>/dev/null && return 0
      ;;
    cursor)
      for src in /opt/cursor/squashfs-root/usr/share/icons/hicolor/256x256/apps/cursor.png /opt/cursor/squashfs-root/cursor.png /opt/cursor/cursor.png; do
        if [ -f "$src" ]; then
          cp "$src" "$target_path" 2>/dev/null && return 0
        fi
      done
      ;;
    windsurf)
      for src in /opt/windsurf/resources/app/resources/linux/code.png /opt/windsurf/resources/app/resources/linux/windsurf.png /usr/share/pixmaps/windsurf.png; do
        if [ -f "$src" ]; then
          cp "$src" "$target_path" 2>/dev/null && return 0
        fi
      done
      ;;
    trainer)
      for src in "${HOME}/constructor-fabric/app/icon.png" "${HOME}/constructor-fabric/assets/constructor-fabric-logo.png"; do
        if [ -f "$src" ]; then
          cp "$src" "$target_path" 2>/dev/null && return 0
        fi
      done
      ;;
    chromium|chrome)
      for src in /usr/share/icons/hicolor/256x256/apps/google-chrome.png /usr/share/pixmaps/google-chrome.png /usr/share/icons/hicolor/256x256/apps/chromium-browser.png /usr/share/pixmaps/chromium-browser.png; do
        if [ -f "$src" ]; then
          cp "$src" "$target_path" 2>/dev/null && return 0
        fi
      done
      ;;
  esac
  
  # If we still don't have an icon, create a placeholder
  create_placeholder_icon "$target_path"
  
  return 0
}

icon_for(){
  app="$1"
  icon_dir="${HOME}/constructor-fabric/app/icons"
  mkdir -p "$icon_dir"
  
  case "$app" in
    vscode)
      target="$icon_dir/codium.png"
      ensure_icon vscode "$target"
      if [ -f "$target" ]; then
        printf '%s\n' "$target"
      else
        printf '%s\n' vscodium
      fi
      ;;
    cursor)
      target="$icon_dir/cursor.png"
      ensure_icon cursor "$target"
      if [ -f "$target" ]; then
        printf '%s\n' "$target"
      else
        printf '%s\n' applications-development
      fi
      ;;
    windsurf)
      target="$icon_dir/windsurf.png"
      ensure_icon windsurf "$target"
      if [ -f "$target" ]; then
        printf '%s\n' "$target"
      else
        printf '%s\n' applications-development
      fi
      ;;
    trainer)
      target="$icon_dir/trainer.png"
      ensure_icon trainer "$target"
      if [ -f "$target" ]; then
        printf '%s\n' "$target"
      else
        printf '%s\n' applications-education
      fi
      ;;
    chromium)
      target="$icon_dir/chromium.png"
      ensure_icon chromium "$target"
      if [ -f "$target" ]; then
        printf '%s\n' "$target"
      else
        printf '%s\n' web-browser
      fi
      ;;
    *) 
      printf '%s\n' applications-development 
      ;;
  esac
}

desktop_link(){
  name="$1"; exec_cmd="$2"; icon_name="$3"; file="$4"; categories="${5:-Development;}"
  
  # Ensure icon exists before creating desktop entry
  if [ -n "$icon_name" ] && [ ! -f "$icon_name" ] && echo "$icon_name" | grep -q "/"; then
    # Icon path doesn't exist, try to ensure it exists
    ensure_icon "$(basename "$icon_name" .png)" "$icon_name"
  fi
  
  cat > "${HOME}/Desktop/$file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Exec=$exec_cmd
Icon=$icon_name
Terminal=false
Categories=$categories
StartupNotify=true
EOF
  chmod 755 "${HOME}/Desktop/$file" || true
  if command -v gio >/dev/null 2>&1; then
    gio set "${HOME}/Desktop/$file" metadata::trusted true >/dev/null 2>&1 || \
      dbus-launch gio set "${HOME}/Desktop/$file" metadata::trusted true >/dev/null 2>&1 || true
  fi
}

ensure_chromium_wrapper(){
  if command -v google-chrome-stable >/dev/null 2>&1; then
    cat > /tmp/constructor-fabric-chromium <<'CHROMIUMWRAP'
#!/bin/sh
exec /usr/bin/google-chrome-stable --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
CHROMIUMWRAP
  elif command -v chromium-browser >/dev/null 2>&1; then
    cat > /tmp/constructor-fabric-chromium <<'CHROMIUMWRAP'
#!/bin/sh
exec /usr/bin/chromium-browser --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
CHROMIUMWRAP
  fi
  mkdir -p "${HOME}/.local/bin"
  sudo cp /tmp/constructor-fabric-chromium /usr/local/bin/constructor-fabric-chromium 2>/dev/null || cp /tmp/constructor-fabric-chromium "${HOME}/.local/bin/constructor-fabric-chromium" 2>/dev/null || true
  sudo chmod 755 /usr/local/bin/constructor-fabric-chromium 2>/dev/null || chmod 755 "${HOME}/.local/bin/constructor-fabric-chromium" 2>/dev/null || true
}

create_gui_launchers(){
  clean_desktop_launchers
  ensure_chromium_wrapper
  
  # Create desktop launchers with icons
  desktop_link "Constructor Fabric Trainer" "${HOME}/constructor-fabric/run-trainer.sh" "$(icon_for trainer)" "Constructor-Fabric-Trainer.desktop"
  
  if command -v constructor-fabric-chromium >/dev/null 2>&1; then
    desktop_link "Chromium" "constructor-fabric-chromium %U" "$(icon_for chromium)" "Chromium.desktop" "Network;WebBrowser;"
  fi
  
  desktop_link "Terminal Emulator" "lxterminal --working-directory=${HOME}/workspaces/constructor-fabric-workspace" "utilities-terminal" "Terminal.desktop" "System;TerminalEmulator;"
  
  if command -v codium >/dev/null 2>&1; then
    desktop_link "VS Codium" "sh -lc 'cd ${HOME}/workspaces/constructor-fabric-workspace && exec codium-wrap --user-data-dir=${HOME}/.config/VSCodium --goto .vscode/cfc-commands.md .'" "$(icon_for vscode)" "VS-Codium.desktop"
  fi
  
  if command -v cursor >/dev/null 2>&1; then
    desktop_link "Cursor" "sh -lc 'cd ${HOME}/workspaces/constructor-fabric-workspace && exec cursor --no-sandbox .'" "$(icon_for cursor)" "Cursor.desktop"
  fi
  
  if command -v windsurf >/dev/null 2>&1; then
    desktop_link "Windsurf" "sh -lc 'cd ${HOME}/workspaces/constructor-fabric-workspace && exec windsurf --no-sandbox .'" "$(icon_for windsurf)" "Windsurf.desktop"
  fi
}

apt_refresh(){ sudo apt-get update >> "$LOG" 2>&1 || true; }
ensure_ide_prereqs(){
  sudo apt-get install -y --no-install-recommends curl wget ca-certificates gnupg apt-transport-https jq xz-utils libnss3 libxss1 libasound2 libgbm1 libgtk-3-0 libsecret-1-0 >> "$LOG" 2>&1 || true
}
install_node22(){
  if [ -x /opt/node-current/bin/node ] && /opt/node-current/bin/node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then return 0; fi
  ensure_ide_prereqs
  log "Installing Node.js 22 for agent CLIs"
  arch="linux-x64"
  url="https://nodejs.org/dist/v22.16.0/node-v22.16.0-$arch.tar.xz"
  curl --noproxy '*' -fL "$url" -o "${HOME}/Downloads/node.tar.xz" >> "$LOG" 2>&1 \
    && sudo rm -rf /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && sudo tar -xJf "${HOME}/Downloads/node.tar.xz" -C /opt \
    && sudo ln -s /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && sudo ln -sf /opt/node-current/bin/node /usr/local/bin/node \
    && sudo ln -sf /opt/node-current/bin/npm /usr/local/bin/npm \
    && sudo ln -sf /opt/node-current/bin/npx /usr/local/bin/npx \
    || log "Node.js install failed; agent CLI installers may be skipped"
}
install_vscode(){
  ensure_ide_prereqs
  log "Installing VS Codium"

  # Purge any old Microsoft VS Code that may be preinstalled in the base image
  if command -v code >/dev/null 2>&1 && ! command -v codium >/dev/null 2>&1; then
    log "Removing old Microsoft VS Code"
    sudo apt-get purge -y code 2>>"$LOG" || true
    sudo apt-get autoremove -y 2>>"$LOG" || true
    sudo rm -f /usr/bin/code /usr/local/bin/code /usr/share/code 2>/dev/null || true
    if [ -d /etc/apt/sources.list.d ]; then
      sudo rm -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/microsoft-prod.list 2>/dev/null || true
    fi
  fi

  if ! command -v codium >/dev/null 2>&1; then
    wget -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg | sudo gpg --dearmor -o /usr/share/keyrings/vscodium-archive-keyring.gpg 2>>"$LOG" || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" | sudo tee /etc/apt/sources.list.d/vscodium.list >/dev/null
    apt_refresh
    timeout 300 sudo apt-get install -y --no-install-recommends codium >> "$LOG" 2>&1 || log "VS Codium install failed; Constructor Fabric CLI remains available"
  fi

  # Force symlink (overwrite stale code binary)
  sudo rm -f /usr/local/bin/code /usr/bin/code 2>/dev/null || true
  sudo ln -sf "$(command -v codium)" /usr/local/bin/code 2>/dev/null || true

  # Container-safe wrapper
  cat > /tmp/codium-wrap <<'WRAP'
#!/bin/sh
exec /usr/bin/codium --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
WRAP
  mkdir -p "${HOME}/.local/bin"
  sudo cp /tmp/codium-wrap /usr/local/bin/codium-wrap 2>/dev/null || cp /tmp/codium-wrap "${HOME}/.local/bin/codium-wrap" 2>/dev/null || true
  sudo chmod +x /usr/local/bin/codium-wrap 2>/dev/null || chmod +x "${HOME}/.local/bin/codium-wrap" 2>/dev/null || true

  # Copy icon to guaranteed path for desktop launcher
  mkdir -p "${HOME}/constructor-fabric/app/icons"
  ensure_icon codium "${HOME}/constructor-fabric/app/icons/codium.png"
}

install_cursor(){
  if command -v cursor >/dev/null 2>&1; then log "Cursor already installed"; return 0; fi
  ensure_ide_prereqs
  log "Installing Cursor"
  sudo mkdir -p /opt/cursor
  curl --noproxy '*' -fsSL "https://cursor.com/api/download?platform=linux-x64" -o /tmp/cursor.tar.gz >> "$LOG" 2>&1 \
    && sudo tar -xzf /tmp/cursor.tar.gz -C /opt/cursor >> "$LOG" 2>&1 \
    && sudo ln -sf /opt/cursor/cursor /usr/local/bin/cursor 2>/dev/null \
    || log "Cursor install failed"
  rm -f /tmp/cursor.tar.gz 2>/dev/null || true
  
  # Ensure icon is available
  mkdir -p "${HOME}/constructor-fabric/app/icons"
  ensure_icon cursor "${HOME}/constructor-fabric/app/icons/cursor.png"
}

install_windsurf(){
  if command -v windsurf >/dev/null 2>&1; then log "Windsurf already installed"; return 0; fi
  ensure_ide_prereqs
  log "Installing Windsurf"
  # Try apt first
  wget -qO- https://api.cursor.com/keys/windsurf.gpg 2>/dev/null | sudo gpg --dearmor -o /usr/share/keyrings/windsurf.gpg 2>/dev/null || true
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/windsurf.gpg] https://api.cursor.com/apt stable main" | sudo tee /etc/apt/sources.list.d/windsurf.list >/dev/null 2>&1 || true
  apt_refresh
  timeout 300 sudo apt-get install -y --no-install-recommends windsurf >> "$LOG" 2>&1 || {
    # Fallback to tarball
    log "Windsurf apt install failed; trying tarball"
    sudo mkdir -p /opt/windsurf
    curl --noproxy '*' -fsSL "https://api.cursor.com/download/windsurf-linux-x64" -o /tmp/windsurf.tar.gz >> "$LOG" 2>&1 \
      && sudo tar -xzf /tmp/windsurf.tar.gz -C /opt/windsurf >> "$LOG" 2>&1 \
      && sudo ln -sf /opt/windsurf/windsurf /usr/local/bin/windsurf 2>/dev/null \
      || log "Windsurf install failed completely"
    rm -f /tmp/windsurf.tar.gz 2>/dev/null || true
  }
  
  # Ensure icon is available
  mkdir -p "${HOME}/constructor-fabric/app/icons"
  ensure_icon windsurf "${HOME}/constructor-fabric/app/icons/windsurf.png"
}

install_codex(){
  if command -v codix >/dev/null 2>&1; then log "Codex already installed"; return 0; fi
  log "Installing OpenAI Codex CLI"
  /opt/node-current/bin/npm install -g @openai/codex >> "$LOG" 2>&1 || log "Codex install failed"
}

install_claude(){
  if command -v claude >/dev/null 2>&1; then log "Claude Code already installed"; return 0; fi
  log "Installing Claude Code CLI"
  /opt/node-current/bin/npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1 || log "Claude Code install failed"
}

install_copilot(){
  if ! command -v codium >/dev/null 2>&1; then
    log "VS Codium not installed; skipping Copilot extension"
    return 0
  fi
  if codium --list-extensions 2>/dev/null | grep -qi github.copilot; then
    log "GitHub Copilot extension already installed"
    return 0
  fi
  log "Installing GitHub Copilot extension for VS Codium"
  # Download .vsix from Microsoft marketplace (Open VSX doesn't have it)
  curl --noproxy '*' -fsSL \
    'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage' \
    -o /tmp/copilot.vsix >> "$LOG" 2>&1 \
    && codium --install-extension /tmp/copilot.vsix >> "$LOG" 2>&1 \
    || log "Copilot extension install failed"
  rm -f /tmp/copilot.vsix 2>/dev/null || true
}

install_copilot_chat(){
  if ! command -v codium >/dev/null 2>&1; then
    log "VS Codium not installed; skipping Copilot Chat extension"
    return 0
  fi
  if codium --list-extensions 2>/dev/null | grep -qi github.copilot-chat; then
    log "GitHub Copilot Chat extension already installed"
    return 0
  fi
  log "Installing GitHub Copilot Chat extension for VS Codium"
  curl --noproxy '*' -fsSL \
    'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot-chat/latest/vspackage' \
    -o /tmp/copilot-chat.vsix >> "$LOG" 2>&1 \
    && codium --install-extension /tmp/copilot-chat.vsix >> "$LOG" 2>&1 \
    || log "Copilot Chat extension install failed"
  rm -f /tmp/copilot-chat.vsix 2>/dev/null || true
}

# Main profile logic
case "$PROFILE" in
  cli)
    log "CLI profile: installing agent CLIs only"
    install_node22
    install_codex
    install_claude
    create_gui_launchers
    ;;
  all)
    log "All profile: installing all IDEs and agent CLIs"
    install_node22
    install_vscode
    install_cursor
    install_windsurf
    install_codex
    install_claude
    install_copilot
    install_copilot_chat
    create_gui_launchers
    ;;
  *)
    log "Unknown profile '$PROFILE'; defaulting to CLI"
    install_node22
    install_codex
    install_claude
    create_gui_launchers
    ;;
esac

log "IDE installation complete"
