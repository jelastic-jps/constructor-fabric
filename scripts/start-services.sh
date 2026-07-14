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

# Suppress the VS Code welcome tab on first open. workbench.startupEditor
# alone is not enough: extensions with an openOnInstall walkthrough (the
# built-in Copilot has one) open the Welcome/walkthrough tab on their first
# activation. These must be user-level settings; merge so keys written by
# other provisioning scripts are preserved.
python3 - "${HOME}/.local/share/code-server/User/settings.json" <<'PYUSERSET'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text()) if p.exists() else {}
except Exception:
    data = {}
data.update({
    'workbench.startupEditor': 'none',
    'workbench.welcomePage.walkthroughs.openOnInstall': False,
    'window.restoreWindows': 'none',
})
data.setdefault('workbench.colorTheme', 'Default Dark Modern')
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2) + '\n')
print('merged welcome-suppression keys into code-server user settings')
PYUSERSET

# Use password from file if manifest already wrote it, otherwise generate
if [ -f "${HOME}/.code-server-password" ] && [ -s "${HOME}/.code-server-password" ]; then
  CODE_SERVER_PASSWORD="$(cat "${HOME}/.code-server-password")"
else
  if [ -z "${CODE_SERVER_PASSWORD:-}" ]; then
    CODE_SERVER_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 16)
  fi
  echo "${CODE_SERVER_PASSWORD}" > "${HOME}/.code-server-password"
  chmod 600 "${HOME}/.code-server-password"
fi
export PASSWORD="${CODE_SERVER_PASSWORD}"
export CODE_SERVER_PASSWORD
echo "[start-services] Password set: ${CODE_SERVER_PASSWORD}"

cat > "${HOME}/.config/code-server/config.yaml" <<CSSERVER
bind-addr: 0.0.0.0:8080
auth: password
cert: false
CSSERVER

# Patch code-server login page message + auto-login from URL
_i18n="/usr/local/out/node/i18n/locales/en.json"
_login="/usr/local/src/browser/pages/login.html"
if [ -f "$_i18n" ]; then
  sudo python3 - "$_i18n" "$_login" <<'PYI18N'
import json, sys
from pathlib import Path

# Patch i18n message
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["LOGIN_USING_ENV_PASSWORD"] = "Your IDE Password"
d["LOGIN_USING_HASHED_PASSWORD"] = "Your IDE Password"
p.write_text(json.dumps(d, indent=4, ensure_ascii=False) + "\n")

# Patch login.html — add auto-login script
lp = Path(sys.argv[2])
html = lp.read_text()
if "autoLoginFromUrl" not in html:
    script = """<script>
(function autoLoginFromUrl(){
  var pw = new URLSearchParams(window.location.search).get("password");
  if (!pw) return;
  var inp = document.querySelector("input.password");
  if (inp) { inp.value = pw; inp.form.submit(); }
})();
</script>"""
    html = html.replace("</body>", script + "\n</body>")
    lp.write_text(html)
    print("[start-services] Patched login.html with auto-login")
PYI18N
fi

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
import re, sys
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text()
# Minified identifier names change between code-server releases, so match the
# guard structurally rather than by exact string.
pattern = re.compile(
    r'(\w+(?:\.\w+)*\.supportGlobalNavigator\|\|)'
    r'Object\.defineProperty\(globalThis,"navigator",'
    r'\{get:\(\)=>\{\w+\(new \w+\("navigator is now a global in nodejs[^"]*"\)\)\}\}\)'
)
replacement = (
    r'\1Object.defineProperty(globalThis,"navigator",'
    r'{value:globalThis.navigator||{userAgent:"Node.js",language:"en-US",'
    r'languages:["en-US"],platform:"Linux"},configurable:!0})'
)
s2, n = pattern.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit("code-server navigator guard pattern not found")
dst.write_text(s2)
print("patched code-server navigator guard for Copilot Chat")
PYNAV
  sudo cp "$tmp" "$target"
  rm -f "$tmp"
}

patch_code_server_navigator_guard

# The core chat setup signs in to GitHub with the FIRST scope list from
# defaultChatAgent.providerScopes, which upstream ships as
# read:user+user:email+repo+workflow. Copilot Chat works with a minimal
# user:email session (it is listed as an accepted alternate), so put the
# minimal scopes first and keep the broader set as a reusable alternate.
# The scope list is read from product.json by node-side consumers but is
# also INLINED into the built workbench bundles at build time, so both
# must be patched for the browser sign-in flow to pick it up.
patch_chat_provider_scopes() {
  vscode_root="/usr/local/lib/vscode"
  [ -d "$vscode_root" ] || return 0
  tmp="/tmp/product.json.$$"
  python3 - "$vscode_root/product.json" "$tmp" <<'PYSCOPES' || true
import json, sys
from pathlib import Path
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
data = json.loads(src.read_text())
agent = data.get('defaultChatAgent') or {}
scopes = agent.get('providerScopes')
if not scopes:
    raise SystemExit('defaultChatAgent.providerScopes not found; skipping')
minimal = ['user:email']
ordered = [s for s in scopes if s == minimal] + [s for s in scopes if s != minimal]
if minimal not in scopes:
    ordered = [minimal] + scopes
if ordered == scopes:
    raise SystemExit(0)
agent['providerScopes'] = ordered
dst.write_text(json.dumps(data, indent=2) + '\n')
print('patched defaultChatAgent.providerScopes in product.json')
PYSCOPES
  if [ -s "$tmp" ]; then
    sudo cp "$tmp" "$vscode_root/product.json"
  fi
  rm -f "$tmp"
  old_literal='providerScopes:[["read:user","user:email","repo","workflow"],["user:email"],["read:user"]]'
  new_literal='providerScopes:[["user:email"],["read:user"],["read:user","user:email","repo","workflow"]]'
  sudo grep -rlF "$old_literal" "$vscode_root/out" 2>/dev/null | while read -r bundle; do
    sudo python3 - "$bundle" "$old_literal" "$new_literal" <<'PYBUNDLE'
import sys
from pathlib import Path
p, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
p.write_text(p.read_text().replace(old, new))
print(f'patched inlined chat provider scopes in {p}')
PYBUNDLE
  done
}

patch_chat_provider_scopes

# User-required right-side AI: GitHub Copilot (completions + Chat).
# code-server 4.127.0 ships the unified "GitHub Copilot" extension as a
# BUILT-IN (/usr/local/lib/vscode/extensions/copilot, copilot-chat 0.55.0),
# which provides both completions and Chat. Do not install GitHub.copilot or
# GitHub.copilot-chat from the marketplace on top of it: copilot-chat is
# rejected as an incompatible downgrade, and reinstalling GitHub.copilot
# aborts with "Please restart VS Code before reinstalling GitHub Copilot".
# Old marketplace copies can still be present in images baked before the
# upgrade; remove them so they cannot shadow or conflict with the built-in.
find "${HOME}/.local/share/code-server/extensions" -maxdepth 1 -type d \
  \( -iname 'github.copilot-[0-9]*' -o -iname 'github.copilot-chat-*' \) \
  -print -exec rm -rf {} + 2>/dev/null || true
registry="${HOME}/.local/share/code-server/extensions/extensions.json"
if [ -f "$registry" ]; then
  python3 - "$registry" <<'PYREG' || true
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
try:
    data = json.loads(p.read_text())
except Exception:
    raise SystemExit(0)
kept = [e for e in data if not str((e.get('identifier') or {}).get('id', '')).lower().startswith('github.copilot')]
if len(kept) != len(data):
    p.write_text(json.dumps(kept, indent=2) + '\n')
    print('pruned stale github.copilot* entries from extensions.json')
PYREG
fi

# Install the Trainer extension from the repo-shipped trainer/ directory —
# the single source of truth for all training content and code
# (trainer/extension + trainer/ui + trainer/content).
EXTENSIONS_DIR="${HOME}/.local/share/code-server/extensions"
TRAINER_EXTENSION_ID="constructor-fabric.constructor-fabric-trainer"
TRAINER_EXTENSION_VERSION="2.0.0"
TRAINER_EXTENSION_DIR="${EXTENSIONS_DIR}/${TRAINER_EXTENSION_ID}-${TRAINER_EXTENSION_VERSION}"

for f in extension/package.json extension/extension.js ui/index.html ui/trainer.js ui/trainer.css content/curriculum.json content/brief.md; do
  if [ ! -s "${TRAINER_DIR}/${f}" ]; then
    echo "trainer file missing or empty: ${TRAINER_DIR}/${f}" >&2
    exit 1
  fi
done
node --check "${TRAINER_DIR}/extension/extension.js"
python3 - "${TRAINER_DIR}/content/curriculum.json" <<'PYCURR'
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data["steps"]) >= 12, "curriculum must have >= 12 steps"
assert data["app"]["port"], "curriculum must define the app port"
print(f"curriculum OK: {len(data['steps'])} steps")
PYCURR

rm -rf "${EXTENSIONS_DIR}/constructor-fabric-trainer" "${EXTENSIONS_DIR}/${TRAINER_EXTENSION_ID}-"*
mkdir -p "$TRAINER_EXTENSION_DIR"
cp "${TRAINER_DIR}/extension/package.json" "${TRAINER_DIR}/extension/extension.js" "$TRAINER_EXTENSION_DIR/"
cp -R "${TRAINER_DIR}/ui" "${TRAINER_DIR}/content" "$TRAINER_EXTENSION_DIR/"

# Older images copied static trainer pages into the workspace; remove the
# stale content but preserve trainer progress (state.json).
rm -f "${CS_WORKSPACE}/.constructor-fabric-trainer/index.html" \
      "${CS_WORKSPACE}/.constructor-fabric-trainer/main.js" \
      "${CS_WORKSPACE}/.constructor-fabric-trainer/package.json" \
      "${CS_WORKSPACE}/.trainer-welcome.html" 2>/dev/null || true

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
_CS_PASS="$(cat "${HOME}/.code-server-password" 2>/dev/null || echo '')"
cat > /tmp/write_supervisor_conf.py << 'PYCONF'
import sys, os
from pathlib import Path
home = '/home/developer'
workspace = os.environ.get('CS_WORKSPACE', home + '/workspaces/constructor-fabric-workspace')
log_dir = os.environ.get('LOG_DIR', home + '/constructor-fabric')
password = sys.argv[1] if len(sys.argv) > 1 else ''
lm_provider = os.environ.get('LLM_PROVIDER', 'openai')
api_token = os.environ.get('API_TOKEN', '')
openai_key = os.environ.get('OPENAI_API_KEY', '')
anthropic_key = os.environ.get('ANTHROPIC_API_KEY', '')
openai_model = os.environ.get('OPENAI_MODEL', 'gpt-5.5')
claude_model = os.environ.get('CLAUDE_MODEL', 'claude-sonnet-4-6')
conf = f'''[program:code-server]
command=/usr/local/bin/code-server --bind-addr 0.0.0.0:8080 --disable-telemetry --disable-workspace-trust --enable-proposed-api GitHub.copilot --enable-proposed-api GitHub.copilot-chat {workspace}
user=developer
directory={workspace}
environment=HOME="{home}",USER="developer",PATH="/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin",PASSWORD={password},LLM_PROVIDER="{lm_provider}",API_TOKEN="{api_token}",OPENAI_API_KEY="{openai_key}",ANTHROPIC_API_KEY="{anthropic_key}",OPENAI_MODEL="{openai_model}",CLAUDE_MODEL="{claude_model}"
autostart=true
autorestart=true
startsecs=5
stdout_logfile={log_dir}/code-server.log
stderr_logfile={log_dir}/code-server.log
stdout_logfile_maxbytes=5MB
'''
Path('/etc/supervisor/conf.d/code-server.conf').write_text(conf)
print(f'[start-services] Supervisor config written, PASSWORD={password[:4]}...')
PYCONF
sudo python3 /tmp/write_supervisor_conf.py "${_CS_PASS}"
rm -f /tmp/write_supervisor_conf.py

sudo supervisorctl reread 2>/dev/null || true
sudo supervisorctl update 2>/dev/null || true
sudo supervisorctl restart code-server 2>/dev/null || true


if [ -x "${HOME}/studio/auto-bootstrap.sh" ]; then
  if ! pgrep -f "studio/auto-bootstrap.sh" >/dev/null 2>&1; then
    setsid sudo -u developer -H "${HOME}/studio/auto-bootstrap.sh" </dev/null >"${HOME}/studio/auto-bootstrap-launch.log" 2>&1 &
  fi
fi

echo "plain code-server configured with inline trainer webview extension"
