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
log(){ echo "[$(date -u +%H:%M:%S)] $*" >> "$LOG"; }
mkdir -p /root/constructor-fabric/app/icons
create_svg_icon(){
  file="$1"; bg="$2"; fg="$3"; label="$4"
  cat > "/root/constructor-fabric/app/icons/$file" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="56" fill="$bg"/>
  <circle cx="196" cy="60" r="28" fill="$fg" opacity="0.22"/>
  <path d="M54 128c0-46 28-76 74-76 36 0 64 20 74 52h-42c-7-10-18-16-32-16-25 0-40 16-40 40s15 40 40 40c15 0 27-6 34-18h42c-10 34-38 54-76 54-46 0-74-30-74-76z" fill="$fg" opacity="0.92"/>
  <text x="128" y="150" text-anchor="middle" font-family="Arial, Helvetica, sans-serif" font-size="58" font-weight="700" fill="$fg">$label</text>
</svg>
EOF
}
create_svg_icon vscode.svg '#0078d4' '#ffffff' 'VS'
create_svg_icon cursor.svg '#111827' '#ffffff' 'Cu'
create_svg_icon windsurf.svg '#00b3a4' '#ffffff' 'Ws'
create_svg_icon codex.svg '#10a37f' '#ffffff' 'Cx'
create_svg_icon claude.svg '#d97706' '#ffffff' 'Cl'
create_svg_icon copilot.svg '#24292f' '#ffffff' 'Gh'
desktop_link(){
  name="$1"; exec_cmd="$2"; icon_name="$3"; file="$4"
  cat > "/root/Desktop/$file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=$name
Exec=$exec_cmd
Icon=$icon_name
Terminal=false
Categories=Development;
EOF
  chmod +x "/root/Desktop/$file" || true
}
PREINSTALLED="$(printenv CF_PREINSTALLED_IDES || true)"
preinstalled_finish(){
  log "Preinstalled IDE image detected; keeping selected profile '$PROFILE' without downloads"
  desktop_link "VS Code - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && code --no-sandbox --user-data-dir=/root/.config/Code . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace'" "/root/constructor-fabric/app/icons/vscode.svg" "VS-Code-Constructor-Fabric.desktop"
  desktop_link "Cursor - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (cursor --no-sandbox . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/cursor.svg" "Cursor-Constructor-Fabric.desktop"
  desktop_link "Windsurf - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (windsurf --no-sandbox . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/windsurf.svg" "Windsurf-Constructor-Fabric.desktop"
  desktop_link "Codex - Constructor Fabric" "lxterminal --title=\"Constructor Fabric - Codex\" --geometry=132x42 -e /root/constructor-fabric/open-agent.sh codex" "/root/constructor-fabric/app/icons/codex.svg" "Codex-Constructor-Fabric.desktop"
  desktop_link "Claude Code - Constructor Fabric" "lxterminal --title=\"Constructor Fabric - Claude Code\" --geometry=132x42 -e /root/constructor-fabric/open-agent.sh claude" "/root/constructor-fabric/app/icons/claude.svg" "Claude-Code-Constructor-Fabric.desktop"
  desktop_link "GitHub Copilot - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (code --no-sandbox --user-data-dir=/root/.config/Code . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/copilot.svg" "GitHub-Copilot-Constructor-Fabric.desktop"
  log "IDE automation finished"
  exit 0
}
if [ "$PREINSTALLED" = "1" ]; then preinstalled_finish; fi
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
  log "Installing VS Code"
  if ! command -v code >/dev/null 2>&1; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg 2>>"$LOG" || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
    apt_refresh
    apt-get install -y --no-install-recommends code >> "$LOG" 2>&1 || log "VS Code install failed; Constructor Fabric CLI remains available"
  fi
  desktop_link "VS Code - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && code --no-sandbox --user-data-dir=/root/.config/Code . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace'" "/root/constructor-fabric/app/icons/vscode.svg" "VS-Code-Constructor-Fabric.desktop"
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
      curl --noproxy '*' -fL "$url" -o /root/Downloads/cursor.AppImage >> "$LOG" 2>&1 \
        && chmod +x /root/Downloads/cursor.AppImage \
        && rm -rf /opt/cursor \
        && mkdir -p /opt/cursor \
        && cd /opt/cursor \
        && /root/Downloads/cursor.AppImage --appimage-extract >> "$LOG" 2>&1 \
        && ln -sf /opt/cursor/squashfs-root/AppRun /usr/local/bin/cursor \
        || log "Cursor AppImage install failed; generated Cursor integration files remain available"
    else
      log "Cursor download API did not return a URL"
    fi
  fi
  desktop_link "Cursor - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (cursor --no-sandbox . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/cursor.svg" "Cursor-Constructor-Fabric.desktop"
}
install_windsurf(){
  ensure_ide_prereqs
  log "Installing Windsurf"
  if ! command -v windsurf >/dev/null 2>&1; then
    curl --noproxy '*' -fsSL 'https://windsurf.com/api/windsurf/download-redirect?build=linux-x64&isNext=false' -o /root/Downloads/windsurf.tar.gz >> "$LOG" 2>&1 \
      && rm -rf /opt/windsurf \
      && mkdir -p /opt/windsurf \
      && tar -xzf /root/Downloads/windsurf.tar.gz -C /opt/windsurf --strip-components=1 \
      && ln -sf /opt/windsurf/windsurf /usr/local/bin/windsurf \
      || log "Windsurf tarball install failed; trying apt repository"
    if ! command -v windsurf >/dev/null 2>&1; then
      curl --noproxy '*' -fsSL https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/windsurf.gpg | gpg --dearmor > /usr/share/keyrings/windsurf.gpg 2>>"$LOG" || true
      echo "deb [signed-by=/usr/share/keyrings/windsurf.gpg arch=amd64] https://windsurf-stable.codeiumdata.com/wVxQEIWkwPUEAGf3/apt stable main" > /etc/apt/sources.list.d/windsurf.list
      apt_refresh
      apt-get install -y --no-install-recommends windsurf >> "$LOG" 2>&1 || log "Windsurf install failed; generated Windsurf integration files remain available"
    fi
  fi
  desktop_link "Windsurf - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (windsurf --no-sandbox . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/windsurf.svg" "Windsurf-Constructor-Fabric.desktop"
}
install_codex(){
  install_node22
  log "Installing OpenAI Codex CLI"
  if ! command -v codex >/dev/null 2>&1 && [ -x /opt/node-current/bin/npm ]; then
    /opt/node-current/bin/npm install -g @openai/codex >> "$LOG" 2>&1 || log "Codex CLI install failed"
    ln -sf /opt/node-current/bin/codex /usr/local/bin/codex || true
  fi
  desktop_link "Codex - Constructor Fabric" "lxterminal --title=\"Constructor Fabric - Codex\" --geometry=132x42 -e /root/constructor-fabric/open-agent.sh codex" "/root/constructor-fabric/app/icons/codex.svg" "Codex-Constructor-Fabric.desktop"
}
install_claude(){
  install_node22
  log "Installing Claude Code CLI"
  if ! command -v claude >/dev/null 2>&1 && [ -x /opt/node-current/bin/npm ]; then
    /opt/node-current/bin/npm install -g @anthropic-ai/claude-code >> "$LOG" 2>&1 || log "Claude Code CLI install failed"
    ln -sf /opt/node-current/bin/claude /usr/local/bin/claude || true
  fi
  desktop_link "Claude Code - Constructor Fabric" "lxterminal --title=\"Constructor Fabric - Claude Code\" --geometry=132x42 -e /root/constructor-fabric/open-agent.sh claude" "/root/constructor-fabric/app/icons/claude.svg" "Claude-Code-Constructor-Fabric.desktop"
}
install_copilot(){
  install_vscode
  log "Preparing GitHub Copilot in VS Code"
  if command -v code >/dev/null 2>&1; then
    code --no-sandbox --user-data-dir=/root/.config/Code --install-extension GitHub.copilot >> "$LOG" 2>&1 || log "GitHub Copilot extension install failed; generated copilot integration files remain available"
    code --no-sandbox --user-data-dir=/root/.config/Code --install-extension GitHub.copilot-chat >> "$LOG" 2>&1 || true
  fi
  desktop_link "GitHub Copilot - Constructor Fabric" "sh -lc 'cd /root/workspaces/constructor-fabric-workspace && (code --no-sandbox --user-data-dir=/root/.config/Code . || lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace)'" "/root/constructor-fabric/app/icons/copilot.svg" "GitHub-Copilot-Constructor-Fabric.desktop"
}
case "$PROFILE" in
  cli|"" ) log "CLI only selected; skipping IDE installers" ;;
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
