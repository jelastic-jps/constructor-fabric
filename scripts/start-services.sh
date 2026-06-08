#!/bin/sh
set -eu

export HOME="${HOME:-/home/developer}"
export USER="${USER:-developer}"
export PATH=/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH

CS_WORKSPACE="${CF_WORKSPACE:-${HOME}/workspaces/constructor-fabric-workspace}"
LOG_DIR="${HOME}/constructor-fabric"
TRAINER_DIR="${HOME}/constructor-fabric/trainer"
mkdir -p "$LOG_DIR" "$CS_WORKSPACE" "${HOME}/.config/code-server" "${HOME}/.local/share/code-server/User"

write_ai_env() {
  # JPS writes the install-form provider/token into this file before switching
  # to the developer user. Source it here because su/sudo/login shells can drop
  # container env vars during bootstrap.
  if [ -f "${HOME}/.constructor-fabric-ai.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${HOME}/.constructor-fabric-ai.env"
    set +a
  fi

  provider="$(printenv LLM_PROVIDER || true)"
  [ -n "$provider" ] || provider=openai
  case "$provider" in openai|claude) ;; *) provider=openai ;; esac

  api_token="$(printenv API_TOKEN || true)"
  openai_key="$(printenv OPENAI_API_KEY || true)"
  anthropic_key="$(printenv ANTHROPIC_API_KEY || true)"
  openai_model="$(printenv OPENAI_MODEL || true)"
  claude_model="$(printenv CLAUDE_MODEL || true)"
  [ -n "$openai_model" ] || openai_model=gpt-5.5
  [ -n "$claude_model" ] || claude_model=claude-sonnet-4-6

  if [ -z "$openai_key" ] && [ "$provider" = "openai" ] && [ -n "$api_token" ]; then openai_key="$api_token"; fi
  if [ -z "$anthropic_key" ] && [ "$provider" = "claude" ] && [ -n "$api_token" ]; then anthropic_key="$api_token"; fi

  umask 077
  cat > "${HOME}/.constructor-fabric-ai.env" <<ENV
LLM_PROVIDER=$provider
API_TOKEN=$api_token
OPENAI_API_KEY=$openai_key
ANTHROPIC_API_KEY=$anthropic_key
OPENAI_MODEL=$openai_model
CLAUDE_MODEL=$claude_model
ENV
  cp "${HOME}/.constructor-fabric-ai.env" "$CS_WORKSPACE/.env" 2>/dev/null || true
  cp "${HOME}/.constructor-fabric-ai.env" "$CS_WORKSPACE/.env.constructor-fabric" 2>/dev/null || true
  mkdir -p "$CS_WORKSPACE/.vscode"
  cat > "$CS_WORKSPACE/.vscode/settings.json" <<'VSCODE'
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.startupPrompt": "never",
  "telemetry.telemetryLevel": "off"
}
VSCODE
}
write_ai_env

cat > "${HOME}/.config/code-server/config.yaml" <<'CSSERVER'
bind-addr: 0.0.0.0:8080
auth: none
cert: false
CSSERVER

cat > "${HOME}/.local/share/code-server/User/settings.json" <<'CSSETTINGS'
{
  "workbench.colorTheme": "Default Dark Modern",
  "workbench.startupEditor": "none",
  "security.workspace.trust.enabled": false,
  "security.workspace.trust.startupPrompt": "never",
  "telemetry.telemetryLevel": "off"
}
CSSETTINGS
python3 - "${HOME}/.local/share/code-server/User/settings.json" <<'PYSETTINGS'
import json, os, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
env = {
    "LLM_PROVIDER": os.environ.get("LLM_PROVIDER", "openai"),
    "OPENAI_MODEL": os.environ.get("OPENAI_MODEL", "gpt-5.5"),
    "CLAUDE_MODEL": os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6"),
}
if os.environ.get("OPENAI_API_KEY"):
    env["OPENAI_API_KEY"] = os.environ["OPENAI_API_KEY"]
if os.environ.get("ANTHROPIC_API_KEY"):
    env["ANTHROPIC_API_KEY"] = os.environ["ANTHROPIC_API_KEY"]
if os.environ.get("API_TOKEN"):
    env["API_TOKEN"] = os.environ["API_TOKEN"]
data["terminal.integrated.env.linux"] = env
p.write_text(json.dumps(data, indent=2) + "\n")
PYSETTINGS

TRAINER_WELCOME_DIR="${CS_WORKSPACE}/.constructor-fabric-trainer"
TRAINER_HTML="${TRAINER_WELCOME_DIR}/index.html"
mkdir -p "$TRAINER_WELCOME_DIR"
if [ -d "$TRAINER_DIR" ]; then
  cp -R "$TRAINER_DIR"/. "$TRAINER_WELCOME_DIR"/ 2>/dev/null || true
fi
if [ ! -f "$TRAINER_HTML" ]; then
  cat > "$TRAINER_HTML" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Constructor Fabric Trainer</title><style>body{margin:0;background:#0f172a;color:#e5e7eb;font-family:system-ui,sans-serif;padding:32px}main{max-width:980px;margin:auto}h1{color:#fff}</style></head><body><main><h1>Constructor Fabric Trainer</h1><p>The trainer is rendered directly inside code-server. No separate trainer service is required.</p></main></body></html>
HTML
fi

TRAINER_EXTENSION_DIR="${HOME}/.local/share/code-server/extensions/constructor-fabric-trainer"
mkdir -p "$TRAINER_EXTENSION_DIR"
cat > "$TRAINER_EXTENSION_DIR/package.json" <<'JSON'
{
  "name": "constructor-fabric-trainer",
  "displayName": "Constructor Fabric Trainer",
  "description": "Opens the Constructor Fabric trainer inside code-server on startup.",
  "version": "1.0.0",
  "publisher": "constructor-fabric",
  "engines": { "vscode": "^1.104.0" },
  "categories": ["Other"],
  "activationEvents": ["onStartupFinished", "onCommand:constructorFabric.openTrainer"],
  "main": "./extension.js",
  "contributes": {
    "commands": [
      { "command": "constructorFabric.openTrainer", "title": "Constructor Fabric: Open Trainer" }
    ]
  }
}
JSON
cat > "$TRAINER_EXTENSION_DIR/extension.js" <<'JS'
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');

let panel;

function workspaceRoot() {
  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length) return folders[0].uri.fsPath;
  return '/home/developer/workspaces/constructor-fabric-workspace';
}

function trainerHtml(root) {
  const candidates = [
    path.join(root, '.constructor-fabric-trainer', 'index.html'),
    path.join(root, '.trainer-welcome.html'),
    '/home/developer/constructor-fabric/trainer/index.html'
  ];
  for (const file of candidates) {
    if (fs.existsSync(file)) return { file, html: fs.readFileSync(file, 'utf8') };
  }
  return { file: null, html: '<!doctype html><h1>Constructor Fabric Trainer</h1><p>Trainer HTML was not found in this workspace.</p>' };
}

function openTrainer(context) {
  const root = workspaceRoot();
  const { file, html } = trainerHtml(root);
  if (panel) {
    panel.reveal(vscode.ViewColumn.One);
  } else {
    panel = vscode.window.createWebviewPanel(
      'constructorFabricTrainer',
      'Constructor Fabric Trainer',
      vscode.ViewColumn.One,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [
          vscode.Uri.file(path.join(root, '.constructor-fabric-trainer')),
          vscode.Uri.file('/home/developer/constructor-fabric/trainer')
        ]
      }
    );
    panel.onDidDispose(() => { panel = undefined; }, null, context.subscriptions);
  }
  panel.webview.html = html;
  if (file) console.log(`Constructor Fabric trainer opened from ${file}`);
}

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand('constructorFabric.openTrainer', () => openTrainer(context)));
  setTimeout(() => openTrainer(context), 1200);
}

function deactivate() {}
module.exports = { activate, deactivate };
JS

PRODUCT_JSON="$(find /usr/local /usr/lib/code-server /usr/share/code-server /opt/node-current -name product.json -path '*/vscode/*' 2>/dev/null | head -1)"
if [ -n "$PRODUCT_JSON" ] && [ -f "$PRODUCT_JSON" ]; then
  python3 - "$PRODUCT_JSON" "$TRAINER_HTML" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
trainer = Path(sys.argv[2]).as_posix()
data = json.loads(p.read_text())
data["welcomePage"] = trainer
data["workbenchColorTheme"] = "Default Dark Modern"
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"product.json welcomePage set to {trainer}")
PY
fi

chown -R developer:developer "$HOME" 2>/dev/null || true

sudo tee /etc/supervisor/conf.d/code-server.conf >/dev/null <<SUPERVISOR
[program:code-server]
command=/usr/local/bin/code-server --bind-addr 0.0.0.0:8080 --auth none --disable-telemetry ${CS_WORKSPACE}
user=developer
directory=${CS_WORKSPACE}
environment=HOME="${HOME}",USER="developer",PATH="/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin"
autostart=true
autorestart=true
startsecs=5
stdout_logfile=${LOG_DIR}/code-server.log
stderr_logfile=${LOG_DIR}/code-server.log
stdout_logfile_maxbytes=5MB
SUPERVISOR


sudo supervisorctl reread 2>/dev/null || true
sudo supervisorctl update 2>/dev/null || true
sudo supervisorctl restart code-server 2>/dev/null || true


if [ -x "${HOME}/cyber-constructor/auto-bootstrap.sh" ]; then
  if ! pgrep -f "cyber-constructor/auto-bootstrap.sh" >/dev/null 2>&1; then
    setsid sudo -u developer -H "${HOME}/cyber-constructor/auto-bootstrap.sh" </dev/null >"${HOME}/cyber-constructor/auto-bootstrap-launch.log" 2>&1 &
  fi
fi

echo "plain code-server configured with inline trainer webview extension"
