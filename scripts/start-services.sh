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

# Generate code-server password if not set
if [ -z "${CODE_SERVER_PASSWORD:-}" ]; then
  CODE_SERVER_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
fi
export PASSWORD="${CODE_SERVER_PASSWORD}"
export CODE_SERVER_PASSWORD
echo "${CODE_SERVER_PASSWORD}" > "${HOME}/.code-server-password"
chmod 600 "${HOME}/.code-server-password"
echo "[start-services] Password set: ${CODE_SERVER_PASSWORD}"

# Write start script that exports PASSWORD before launching code-server
cat > "${HOME}/start-code-server.sh" <<STARTSCRIPT
#!/bin/sh
export PASSWORD="\$(cat "\${HOME}/.code-server-password")"
exec /usr/local/bin/code-server --bind-addr 0.0.0.0:8080 --disable-telemetry --enable-proposed-api GitHub.copilot --enable-proposed-api GitHub.copilot-chat "\${1:-\${HOME}/workspaces/constructor-fabric-workspace}"
STARTSCRIPT
chmod +x "${HOME}/start-code-server.sh"

cat > "${HOME}/.config/code-server/config.yaml" <<'CSSERVER'
bind-addr: 0.0.0.0:8080
auth: password
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
data["window.restoreWindows"] = "none"
data["workbench.editor.restoreViewState"] = False
data["workbench.tips.enabled"] = False
data["update.mode"] = "none"
data["extensions.autoCheckUpdates"] = False
data["extensions.autoUpdate"] = False
data["github.copilot.enable"] = {"*": True, "plaintext": True, "markdown": True, "scminput": True}
data["github.copilot.editor.enableAutoCompletions"] = True
data["chat.commandCenter.enabled"] = True
data["workbench.commandPalette.experimental.askChatLocation"] = "chatView"
p.write_text(json.dumps(data, indent=2) + "\n")
PYSETTINGS

patch_code_server_navigator_guard() {
  target="/usr/local/lib/vscode/out/vs/workbench/api/node/extensionHostProcess.js"
  [ -f "$target" ] || return 0
  if grep -q 'value:globalThis.navigator' "$target" 2>/dev/null; then
    echo "code-server navigator guard already patched"
    return 0
  fi
  tmp="/tmp/extensionHostProcess.js.$$"
  python3 - "$target" "$tmp" <<'PYNAV'
from pathlib import Path
import sys
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text()
old = 'zh.supportGlobalNavigator||Object.defineProperty(globalThis,"navigator",{get:()=>{td(new p1("navigator is now a global in nodejs, please see https://aka.ms/vscode-extensions/navigator for additional info on this error."))}});'
new = 'zh.supportGlobalNavigator||Object.defineProperty(globalThis,"navigator",{value:globalThis.navigator||{userAgent:"Node.js",language:"en-US",languages:["en-US"],platform:"Linux"},configurable:!0});'
if old not in s:
    raise SystemExit("code-server navigator guard pattern not found")
dst.write_text(s.replace(old, new, 1))
print("patched code-server navigator guard for Copilot Chat")
PYNAV
  sudo cp "$tmp" "$target"
  rm -f "$tmp"
}

patch_code_server_navigator_guard

install_code_server_vsix() {
  publisher="$1"
  ext="$2"
  version="$3"
  id="${publisher}.${ext}"
  ext_dir="${HOME}/.local/share/code-server/extensions"
  vsix="/tmp/${ext}.vsix"
  mkdir -p "$ext_dir"
  rm -f "${HOME}/.local/share/code-server/extensions/.obsolete" 2>/dev/null || true
  expected_dir="${ext_dir}/$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')-${version}"
  if [ -d "$expected_dir" ]; then
    echo "${id}@${version} already installed"
    return 0
  fi
  # The Docker image can contain an older baked extension version. code-server
  # --list-extensions only reports the id, not the version, so remove old copies
  # before installing the pinned compatible version.
  find "$ext_dir" -maxdepth 1 -type d -iname "${id}-*" ! -path "$expected_dir" -print -exec rm -rf {} + 2>/dev/null || true
  echo "Installing ${id}@${version} for code-server"
  curl --noproxy '*' -fL -H 'Accept: application/octet-stream' -H 'User-Agent: Mozilla/5.0' \
    "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/${publisher}/vsextensions/${ext}/${version}/vspackage" \
    -o "$vsix"
  python3 - "$vsix" <<'PYVSIX'
import gzip, sys
from pathlib import Path
p = Path(sys.argv[1])
b = p.read_bytes()
if b.startswith(b'\x1f\x8b'):
    p.write_bytes(gzip.decompress(b))
    b = p.read_bytes()
if not b.startswith(b'PK'):
    raise SystemExit(f'{p} is not a VSIX/zip payload')
PYVSIX
  code-server --install-extension "$vsix" --force --extensions-dir "$ext_dir"
  rm -f "$vsix"
}

# User-required right-side AI: install GitHub Copilot and Copilot Chat.
# Do not use the VS Code desktop-only --disable-extension flag; code-server 4.104.2
# rejects it and that was the direct cause of the failed install.
install_code_server_vsix GitHub copilot latest || echo "GitHub Copilot install failed; continuing"
install_code_server_vsix GitHub copilot-chat 0.31.1 || echo "GitHub Copilot Chat install failed; continuing"

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

EXTENSIONS_DIR="${HOME}/.local/share/code-server/extensions"
TRAINER_EXTENSION_ID="constructor-fabric.constructor-fabric-trainer"
TRAINER_EXTENSION_VERSION="1.0.0"
TRAINER_EXTENSION_DIR="${EXTENSIONS_DIR}/${TRAINER_EXTENSION_ID}-${TRAINER_EXTENSION_VERSION}"
rm -rf "${EXTENSIONS_DIR}/constructor-fabric-trainer" "${TRAINER_EXTENSION_DIR}"
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
  "activationEvents": [
    "*",
    "onStartupFinished",
    "onCommand:constructorFabric.openTrainer",
    "onCommand:workbench.action.chat.triggerSetupForceSignIn"
  ],
  "main": "./extension.js",
  "contributes": {
    "commands": [
      { "command": "constructorFabric.openTrainer", "title": "Constructor Fabric: Open Trainer" },
      { "command": "workbench.action.chat.triggerSetupForceSignIn", "title": "Constructor Fabric: Sign in to Copilot" }
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

async function triggerCopilotSignIn() {
  const commands = await vscode.commands.getCommands(true);
  const candidates = [
    'github.copilot.signIn',
    'github.copilot.chat.signIn',
    'github.copilot.interactiveSession.signIn',
    'github.copilot.acceptDeviceCode'
  ];
  for (const command of candidates) {
    if (commands.includes(command)) {
      console.log(`Forwarding Copilot sign-in to ${command}`);
      return vscode.commands.executeCommand(command);
    }
  }
  try {
    // Copilot Chat does not accept a minimal user:email GitHub session. It
    // repeatedly logs GitHubLoginFailed when only user:email exists. Request
    // the broader scopes that the GitHub auth extension checks for Copilot.
    const scopes = ['read:user', 'repo', 'user:email', 'workflow'];
    await vscode.authentication.getSession('github', scopes, { createIfNone: true });
    vscode.window.showInformationMessage('GitHub Copilot sign-in started. Complete auth, then reload this browser tab if Copilot Chat does not refresh automatically.');
  } catch (error) {
    vscode.window.showErrorMessage(`GitHub Copilot sign-in failed to start: ${error && error.message ? error.message : String(error)}`);
    throw error;
  }
}

function activate(context) {
  context.subscriptions.push(vscode.commands.registerCommand('constructorFabric.openTrainer', () => openTrainer(context)));
  context.subscriptions.push(vscode.commands.registerCommand('workbench.action.chat.triggerSetupForceSignIn', triggerCopilotSignIn));
  openTrainer(context);
  setTimeout(() => openTrainer(context), 700);
  setTimeout(() => openTrainer(context), 2000);
}

function deactivate() {}
module.exports = { activate, deactivate };
JS

# Register the local trainer extension in code-server's user extension registry.
# A bare directory with package.json is not reliably discovered after Marketplace
# installs rewrite extensions.json; registration makes startup activation stable.
python3 - "$EXTENSIONS_DIR" "$TRAINER_EXTENSION_DIR" "$TRAINER_EXTENSION_ID" "$TRAINER_EXTENSION_VERSION" <<'PYEXTREG'
import json, sys
from pathlib import Path
extensions_dir = Path(sys.argv[1])
extension_dir = Path(sys.argv[2])
extension_id = sys.argv[3]
version = sys.argv[4]
extensions_dir.mkdir(parents=True, exist_ok=True)
registry = extensions_dir / 'extensions.json'
try:
    data = json.loads(registry.read_text()) if registry.exists() else []
except Exception:
    data = []
data = [e for e in data if (e.get('identifier') or {}).get('id') != extension_id and e.get('identifier', {}).get('value') != extension_id]
data.append({
    'identifier': {'id': extension_id, 'uuid': extension_id},
    'version': version,
    'location': {'$mid': 1, 'path': str(extension_dir), 'scheme': 'file'},
    'relativeLocation': extension_dir.name,
    'metadata': {
        'id': extension_id,
        'publisherId': 'constructor-fabric',
        'publisherDisplayName': 'Constructor Fabric',
        'installedTimestamp': 0,
        'isPreReleaseVersion': False
    },
    'targetPlatform': 'undefined',
    'isBuiltin': False
})
registry.write_text(json.dumps(data, indent=2) + '\n')
print(f'registered {extension_id} at {extension_dir}')
PYEXTREG

# Do not patch code-server's root-owned product.json. The trainer is opened by
# the local Webview extension above; product.json welcomePage is unreliable for
# arbitrary local trainer HTML and fails on fresh installs when run as developer.
chown -R developer:developer "$HOME" 2>/dev/null || true

# Write supervisor config for code-server via Python (reliable variable injection)
sudo python3 -c "
from pathlib import Path
home = '${HOME}'
workspace = '${CS_WORKSPACE}'
log_dir = '${LOG_DIR}'
# Read password from file (shell variable may be empty)
pw_file = Path(home) / '.code-server-password'
password = pw_file.read_text().strip() if pw_file.exists() else ''
lm_provider = '${LLM_PROVIDER:-openai}'
api_token = '${API_TOKEN:-}'
openai_key = '${OPENAI_API_KEY:-}'
anthropic_key = '${ANTHROPIC_API_KEY:-}'
openai_model = '${OPENAI_MODEL:-gpt-5.5}'
claude_model = '${CLAUDE_MODEL:-claude-sonnet-4-6}'
log_dir = '${LOG_DIR}'
conf = f'''[program:code-server]
command=/usr/local/bin/code-server --bind-addr 0.0.0.0:8080 --disable-telemetry --enable-proposed-api GitHub.copilot --enable-proposed-api GitHub.copilot-chat {workspace}
user=developer
directory={workspace}
environment=HOME=\"{home}\",USER=\"developer\",PATH=\"/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin\",PASSWORD=\"{password}\",LLM_PROVIDER=\"{lm_provider}\",API_TOKEN=\"{api_token}\",OPENAI_API_KEY=\"{openai_key}\",ANTHROPIC_API_KEY=\"{anthropic_key}\",OPENAI_MODEL=\"{openai_model}\",CLAUDE_MODEL=\"{claude_model}\"
autostart=true
autorestart=true
startsecs=5
stdout_logfile={log_dir}/code-server.log
stderr_logfile={log_dir}/code-server.log
stdout_logfile_maxbytes=5MB
'''
Path('/etc/supervisor/conf.d/code-server.conf').write_text(conf)
print(f'[start-services] Supervisor config written, password={password[:4]}...')
"

sudo supervisorctl reread 2>/dev/null || true
sudo supervisorctl update 2>/dev/null || true
sudo supervisorctl restart code-server 2>/dev/null || true


if [ -x "${HOME}/cyber-constructor/auto-bootstrap.sh" ]; then
  if ! pgrep -f "cyber-constructor/auto-bootstrap.sh" >/dev/null 2>&1; then
    setsid sudo -u developer -H "${HOME}/cyber-constructor/auto-bootstrap.sh" </dev/null >"${HOME}/cyber-constructor/auto-bootstrap-launch.log" 2>&1 &
  fi
fi

echo "plain code-server configured with inline trainer webview extension"
