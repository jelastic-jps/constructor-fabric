#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
export DISPLAY=:1
export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH
PROFILE="$(printenv CF_IDE_PROFILE || true)"
if [ -z "$PROFILE" ]; then PROFILE=cli; fi
LOG=/root/constructor-fabric/ide-install.log
mkdir -p /root/constructor-fabric /root/Desktop /root/Downloads /opt
echo "Constructor Fabric IDE automation profile: $PROFILE" > "$LOG"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
mkdir -p /root/constructor-fabric/app/icons

# Keep the visible desktop clean and useful: no fake letter icons and no terminal-only
# agent shortcuts. Claude/Codex integrations are generated for the IDEs, but the
# desktop must launch real GUI IDEs plus the trainer.
clean_desktop_launchers(){
  mkdir -p /root/Desktop
  rm -f /root/Desktop/*.desktop 2>/dev/null || true
}

icon_for(){
  app="$1"
  case "$app" in
    vscode)
      for f in /root/constructor-fabric/app/icons/codium.png /usr/share/pixmaps/codium.png /usr/share/icons/hicolor/256x256/apps/codium.png /usr/share/icons/hicolor/256x256/apps/vscodium.png /usr/share/codium/resources/app/resources/linux/code.png; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
      done
      printf '%s\n' vscodium
      ;;
    cursor)
      for f in /opt/cursor/squashfs-root/usr/share/icons/hicolor/256x256/apps/cursor.png /opt/cursor/squashfs-root/cursor.png /opt/cursor/cursor.png; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
      done
      printf '%s\n' applications-development
      ;;
    windsurf)
      for f in /opt/windsurf/resources/app/resources/linux/code.png /opt/windsurf/resources/app/resources/linux/windsurf.png /usr/share/pixmaps/windsurf.png; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
      done
      printf '%s\n' applications-development
      ;;
    trainer)
      [ -f /root/constructor-fabric/app/icon.png ] && printf '%s\n' /root/constructor-fabric/app/icon.png || printf '%s\n' applications-education
      ;;
    chromium)
      for f in /usr/share/icons/hicolor/256x256/apps/google-chrome.png /usr/share/pixmaps/google-chrome.png /usr/share/icons/hicolor/256x256/apps/chromium-browser.png /usr/share/pixmaps/chromium-browser.png; do
        [ -f "$f" ] && { printf '%s\n' "$f"; return; }
      done
      printf '%s\n' web-browser
      ;;
    *) printf '%s\n' applications-development ;;
  esac
}

desktop_link(){
  name="$1"; exec_cmd="$2"; icon_name="$3"; file="$4"; categories="${5:-Development;}"
  cat > "/root/Desktop/$file" <<EOF
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
  chmod 755 "/root/Desktop/$file" || true
  if command -v gio >/dev/null 2>&1; then
    gio set "/root/Desktop/$file" metadata::trusted true >/dev/null 2>&1 || \
      dbus-launch gio set "/root/Desktop/$file" metadata::trusted true >/dev/null 2>&1 || true
  fi
}

ensure_chromium_wrapper(){
  if command -v google-chrome-stable >/dev/null 2>&1; then
    cat > /usr/local/bin/constructor-fabric-chromium <<'CHROMIUMWRAP'
#!/bin/sh
exec /usr/bin/google-chrome-stable --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
CHROMIUMWRAP
  elif command -v chromium-browser >/dev/null 2>&1; then
    cat > /usr/local/bin/constructor-fabric-chromium <<'CHROMIUMWRAP'
#!/bin/sh
exec /usr/bin/chromium-browser --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
CHROMIUMWRAP
  fi
  chmod 755 /usr/local/bin/constructor-fabric-chromium 2>/dev/null || true
}

create_gui_launchers(){
  clean_desktop_launchers
  ensure_chromium_wrapper
  desktop_link "Constructor Fabric Trainer" "/root/constructor-fabric/run-trainer.sh" "$(icon_for trainer)" "Constructor-Fabric-Trainer.desktop"
  if [ -x /usr/local/bin/constructor-fabric-chromium ]; then
    desktop_link "Chromium" "/usr/local/bin/constructor-fabric-chromium %U" "$(icon_for chromium)" "Chromium.desktop" "Network;WebBrowser;"
  fi
  desktop_link "Terminal Emulator" "lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace" "utilities-terminal" "Terminal.desktop" "System;TerminalEmulator;"
  if command -v codium >/dev/null 2>&1; then
    desktop_link "VS Codium" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && exec /usr/local/bin/codium-wrap --user-data-dir=/root/.config/VSCodium --goto .vscode/cfc-commands.md .'" "$(icon_for vscode)" "VS-Codium.desktop"
  fi
  if command -v cursor >/dev/null 2>&1; then
    desktop_link "Cursor" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && exec cursor --no-sandbox .'" "$(icon_for cursor)" "Cursor.desktop"
  fi
  if command -v windsurf >/dev/null 2>&1; then
    desktop_link "Windsurf" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && exec windsurf --no-sandbox .'" "$(icon_for windsurf)" "Windsurf.desktop"
  fi
}

apt_refresh(){ apt-get update >> "$LOG" 2>&1 || true; }
ensure_ide_prereqs(){
  apt-get install -y --no-install-recommends curl wget ca-certificates gnupg apt-transport-https jq xz-utils libnss3 libxss1 libasound2 libgbm1 libgtk-3-0 libsecret-1-0 >> "$LOG" 2>&1 || true
}
install_node22(){
  if [ -x /opt/node-current/bin/node ] && /opt/node-current/bin/node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 22 ? 0 : 1)' >/dev/null 2>&1; then return 0; fi
  ensure_ide_prereqs
  log "Installing Node.js 22 for agent CLIs"
  arch="linux-x64"
  url="https://nodejs.org/dist/v22.16.0/node-v22.16.0-$arch.tar.xz"
  curl --noproxy '*' -fL "$url" -o /root/Downloads/node.tar.xz >> "$LOG" 2>&1 \
    && rm -rf /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && tar -xJf /root/Downloads/node.tar.xz -C /opt \
    && ln -s /opt/node-v22.16.0-linux-x64 /opt/node-current \
    && ln -sf /opt/node-current/bin/node /usr/local/bin/node \
    && ln -sf /opt/node-current/bin/npm /usr/local/bin/npm \
    && ln -sf /opt/node-current/bin/npx /usr/local/bin/npx \
    || log "Node.js install failed; agent CLI installers may be skipped"
}
install_vscode(){
  ensure_ide_prereqs
  log "Installing VS Codium"

  # Purge any old Microsoft VS Code that may be preinstalled in the base image
  if command -v code >/dev/null 2>&1 && ! command -v codium >/dev/null 2>&1; then
    log "Removing old Microsoft VS Code"
    apt-get purge -y code 2>>"$LOG" || true
    apt-get autoremove -y 2>>"$LOG" || true
    rm -f /usr/bin/code /usr/local/bin/code /usr/share/code 2>/dev/null || true
    if [ -d /etc/apt/sources.list.d ]; then
      rm -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/microsoft-prod.list 2>/dev/null || true
    fi
  fi

  if ! command -v codium >/dev/null 2>&1; then
    wget -qO- https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg | gpg --dearmor > /usr/share/keyrings/vscodium-archive-keyring.gpg 2>>"$LOG" || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] https://download.vscodium.com/debs vscodium main" > /etc/apt/sources.list.d/vscodium.list
    apt_refresh
    timeout 300 apt-get install -y --no-install-recommends codium >> "$LOG" 2>&1 || log "VS Codium install failed; Constructor Fabric CLI remains available"
  fi

  if command -v codium >/dev/null 2>&1; then
    # Force symlink code -> codium so agent CLIs (Copilot, etc.) that expect 'code' still work.
    # Remove any stale code binary first so the symlink always takes effect.
    rm -f /usr/local/bin/code /usr/bin/code 2>/dev/null || true
    ln -sf "$(command -v codium)" /usr/local/bin/code || true

    # Create a container-safe wrapper (like cursor has) so codium always
    # runs with the flags required under root inside Docker.
    cat > /usr/local/bin/codium-wrap <<'CODIUMWRAP'
#!/bin/sh
exec /usr/bin/codium --no-sandbox --disable-gpu --disable-dev-shm-usage "$@"
CODIUMWRAP
    chmod +x /usr/local/bin/codium-wrap

    # Copy the codium icon to a guaranteed path so the desktop launcher icon always resolves
    for candidate in \
      /usr/share/pixmaps/codium.png \
      /usr/share/icons/hicolor/256x256/apps/codium.png \
      /usr/share/icons/hicolor/256x256/apps/vscodium.png \
      /usr/share/codium/resources/app/resources/linux/code.png; do
      if [ -f "$candidate" ]; then
        cp -f "$candidate" /root/constructor-fabric/app/icons/codium.png 2>/dev/null || true
        break
      fi
    done
    # If no icon was found, download the official VSCodium logo as fallback
    if [ ! -f /root/constructor-fabric/app/icons/codium.png ]; then
      curl --noproxy '*' -fsSL https://raw.githubusercontent.com/VSCodium/vscodium/master/icons/stable.png \
        -o /root/constructor-fabric/app/icons/codium.png 2>/dev/null || true
    fi
  fi

  create_gui_launchers
}
install_cursor(){
  ensure_ide_prereqs
  log "Installing Cursor"
  if ! command -v cursor >/dev/null 2>&1; then
    api=/root/Downloads/cursor-download.json
    curl --noproxy '*' -fsSL 'https://cursor.com/api/download?platform=linux-x64&releaseTrack=stable' -o "$api" >> "$LOG" 2>&1 || true
    url=$(python3 - <<'PYCURSOR' 2>>"$LOG"
import json
from pathlib import Path
p=Path('/root/Downloads/cursor-download.json')
data=json.loads(p.read_text()) if p.exists() else {}
print(data.get('downloadUrl') or data.get('url') or '')
PYCURSOR
)
    if [ -n "$url" ]; then
      rm -rf /opt/cursor
      mkdir -p /opt/cursor
      if timeout 300 curl --noproxy '*' -fL "$url" -o /opt/cursor/cursor.AppImage >> "$LOG" 2>&1; then
        chmod +x /opt/cursor/cursor.AppImage
        cat > /usr/local/bin/cursor <<'CURSORWRAP'
#!/bin/sh
exec /opt/cursor/cursor.AppImage --no-sandbox "$@"
CURSORWRAP
        chmod +x /usr/local/bin/cursor
      else
        log "Cursor AppImage download failed; generated Cursor integration files remain available"
      fi
    else
      log "Cursor download API did not return a URL"
    fi
  fi
  create_gui_launchers
}
install_windsurf(){
  ensure_ide_prereqs
  log "Installing Windsurf"
  if ! command -v windsurf >/dev/null 2>&1; then
      timeout 300 curl --noproxy '*' -fsSL 'https://windsurf.com/api/windsurf/download-redirect?build=linux-x64&isNext=false' -o /root/Downloads/windsurf.tar.gz >> "$LOG" 2>&1 \
      && rm -rf /opt/windsurf \
      && mkdir -p /opt/windsurf \
      && tar -xzf /root/Downloads/windsurf.tar.gz -C /opt/windsurf --strip-components=1 \
      && windsurf_bin="$(find /opt/windsurf -maxdepth 4 -type f -perm -111 \( -name windsurf -o -name Windsurf -o -name AppRun \) | head -1)" \
      && [ -n "$windsurf_bin" ] \
      && ln -sf "$windsurf_bin" /usr/local/bin/windsurf \
      || log "Windsurf tarball install failed; trying apt repository"
    if ! command -v windsurf >/dev/null 2>&1; then
      curl --noproxy '*' -fsSL https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/windsurf.gpg | gpg --dearmor > /usr/share/keyrings/windsurf.gpg 2>>"$LOG" || true
      echo "deb [signed-by=/usr/share/keyrings/windsurf.gpg arch=amd64] https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/apt stable main" > /etc/apt/sources.list.d/windsurf.list
      apt_refresh
      timeout 300 apt-get install -y --no-install-recommends windsurf >> "$LOG" 2>&1 || log "Windsurf install failed; generated Windsurf integration files remain available"
    fi
  fi
  create_gui_launchers
}
install_codex(){
  install_node22
  log "Installing OpenAI Codex CLI"
  if ! command -v codex >/dev/null 2>&1 && [ -x /opt/node-current/bin/npm ]; then
    timeout --kill-after=10s 120s env NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_PROGRESS=false /opt/node-current/bin/npm install -g @openai/codex >> "$LOG" 2>&1 || log "Codex CLI install failed; creating npx fallback wrapper"
    if [ -x /opt/node-current/bin/codex ]; then
      ln -sf /opt/node-current/bin/codex /usr/local/bin/codex || true
    elif ! command -v codex >/dev/null 2>&1; then
      cat > /usr/local/bin/codex <<'CODEXWRAP'
#!/bin/sh
exec /opt/node-current/bin/npx -y @openai/codex "$@"
CODEXWRAP
      chmod +x /usr/local/bin/codex
    fi
  fi
  create_gui_launchers
}
install_claude(){
  install_node22
  log "Installing Claude Code CLI"
  if ! command -v claude >/dev/null 2>&1 && [ -x /opt/node-current/bin/npm ]; then
    timeout --kill-after=10s 120s env NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_PROGRESS=false /opt/node-current/bin/npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1 || log "Claude Code CLI install failed; creating npx fallback wrapper"
    if [ -x /opt/node-current/bin/claude ]; then
      ln -sf /opt/node-current/bin/claude /usr/local/bin/claude || true
    elif ! command -v claude >/dev/null 2>&1; then
      cat > /usr/local/bin/claude <<'CLAUDEWRAP'
#!/bin/sh
exec /opt/node-current/bin/npx -y @anthropic-ai/claude-code "$@"
CLAUDEWRAP
      chmod +x /usr/local/bin/claude
    fi
  fi
  create_gui_launchers
}
install_copilot(){
  install_vscode
  log "Preparing GitHub Copilot in VS Codium"
  if command -v codium >/dev/null 2>&1; then
    # VS Codium uses Open VSX registry by default, which doesn't carry
    # Microsoft-proprietary extensions. Download .vsix directly from
    # Microsoft marketplace and install from local files.
    copilot_vsix=/root/Downloads/github-copilot.vsix
    copilot_chat_vsix=/root/Downloads/github-copilot-chat.vsix
    if [ ! -f "$copilot_vsix" ]; then
      curl --noproxy '*' -fsSL \
        'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage' \
        -o "$copilot_vsix" >> "$LOG" 2>&1 || true
    fi
    if [ ! -f "$copilot_chat_vsix" ]; then
      curl --noproxy '*' -fsSL \
        'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot-chat/latest/vspackage' \
        -o "$copilot_chat_vsix" >> "$LOG" 2>&1 || true
    fi
    if [ -f "$copilot_vsix" ] && [ -s "$copilot_vsix" ]; then
      timeout 120 /usr/local/bin/codium-wrap --user-data-dir=/root/.config/VSCodium --install-extension "$copilot_vsix" >> "$LOG" 2>&1 \
        && log "GitHub Copilot installed" \
        || log "GitHub Copilot extension install failed; generated copilot integration files remain available"
    else
      log "GitHub Copilot .vsix download failed; skipping extension install"
    fi
    if [ -f "$copilot_chat_vsix" ] && [ -s "$copilot_chat_vsix" ]; then
      timeout 120 /usr/local/bin/codium-wrap --user-data-dir=/root/.config/VSCodium --install-extension "$copilot_chat_vsix" >> "$LOG" 2>&1 \
        && log "GitHub Copilot Chat installed" \
        || log "GitHub Copilot Chat install failed"
    fi
  fi

  # Pre-configure VS Codium workspace settings for Constructor Fabric workflow.
  # When the user opens VS Codium, Copilot Chat panel is the recommended place
  # to paste /cf-constructor commands.
  local ws=/root/workspaces/constructor-fabric-workspace
  mkdir -p "$ws/.vscode"
  cat > "$ws/.vscode/settings.json" <<'VSCODESETTINGS'
{
  "workbench.startupEditor": "none",
  "chat.commandCenter.enabled": true,
  "github.copilot.enable": {
    "*": true
  },
  "github.copilot.chat.localeOverride": "auto",
  "terminal.integrated.defaultLocation": "editor"
}
VSCODESETTINGS

  cat > "$ws/.vscode/cfc-commands.md" <<'CFCHEATSHEET'
# Constructor Fabric Quick Start

Paste these commands into the Copilot Chat panel (Ctrl+Shift+I or Cmd+Shift+I):

```
/cf-constructor Create a PRD for [your product idea]
```

```
/cf-constructor Decompose the PRD into feature artifacts
```

```
/cf-constructor Create an implementation task backlog for these features
```

```
/cf-constructor Produce implementation plans for the task backlog
```

## Validate your work
```
cfc validate
cfc list-ids  
cfc toc
```
CFCHEATSHEET

  create_gui_launchers
}
case "$PROFILE" in
  cli|"" ) log "CLI only selected; downloads skipped; creating GUI desktop launchers from preinstalled IDEs"; create_gui_launchers ;;
  vscode ) install_vscode ;;
  cursor ) install_cursor ;;
  windsurf ) install_windsurf ;;
  codex ) install_codex ;;
  claude ) install_claude ;;
  copilot ) install_copilot ;;
  all ) install_vscode; install_cursor; install_windsurf; install_codex; install_claude; install_copilot ;;
  * ) log "Unknown profile '$PROFILE'; leaving CLI-only" ;;
esac
log "IDE automation finished"
