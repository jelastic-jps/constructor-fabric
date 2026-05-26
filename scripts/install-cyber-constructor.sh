#!/bin/sh
set -eu
export HOME=/root
export PATH=/root/.local/bin:/usr/local/bin:$PATH
mkdir -p /root/cyber-constructor /root/.cf-constructor/cache /root/cfc-install
cd /root/cfc-install
echo "Fetching Cyber Constructor local source archive"
curl --noproxy '*' -fsSL "https://files.catbox.moe/qb6e6d.gz" -o cyber-constructor.tar.gz
echo "8ca1c8005097cb3bdca521888a61cc3f0c508601a199722d2585e3130703a626  cyber-constructor.tar.gz" | sha256sum -c -
rm -rf /root/cyber-constructor
mkdir -p /root/cyber-constructor
tar -xzf cyber-constructor.tar.gz -C /root/cyber-constructor
find /root/cyber-constructor \( -name '._*' -o -name '.DS_Store' \) -delete
if [ ! -x /root/.local/bin/uv ]; then
  wget -q https://astral.sh/uv/install.sh -O /root/install-uv.sh
  sh /root/install-uv.sh >/root/cfc-install/uv-install.log 2>&1
fi
/root/.local/bin/uv python install 3.11 >/root/cfc-install/uv-python311.log 2>&1
cd /root/cyber-constructor
/root/.local/bin/uv venv --python 3.11 /root/cyber-constructor/.venv >/root/cfc-install/venv.log 2>&1
/root/.local/bin/uv pip install --python /root/cyber-constructor/.venv/bin/python -e /root/cyber-constructor >/root/cfc-install/pip-install.log 2>&1
ln -sf /root/cyber-constructor/.venv/bin/cfc /usr/local/bin/cfc
ln -sf /root/cyber-constructor/.venv/bin/cf-constructor /usr/local/bin/cf-constructor
rm -rf /root/.cf-constructor/cache
mkdir -p /root/.cf-constructor/cache
cp -a /root/cyber-constructor/skills /root/.cf-constructor/cache/
if [ -d /root/cyber-constructor/config ]; then cp -a /root/cyber-constructor/config /root/.cf-constructor/cache/; fi
echo v4.0.0 > /root/.cf-constructor/cache/.version
printf 'd\n' | cfc init --no-cache --project-root /root/cyber-constructor --install-dir .cf-constructor --project-name cyber-constructor --force >/root/cfc-install/init.log 2>&1
cfc generate-agents --root /root/cyber-constructor -y >/root/cfc-install/generate-agents.log 2>&1
cat > /root/cyber-constructor/auto-bootstrap.sh <<'CFCAUTO'
#!/bin/bash
set -euo pipefail
export HOME=/root
export PATH=/root/cyber-constructor/.venv/bin:/root/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
LOG=/root/cyber-constructor/auto-bootstrap.log
exec >>"$LOG" 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Constructor Fabric auto-bootstrap started"

provider="$(printenv LLM_PROVIDER || true)"
if [ -z "$provider" ]; then provider=openai; fi
case "$provider" in openai|claude) ;; *) provider=openai ;; esac
if [ "$provider" = "claude" ]; then
  model="$(printenv CLAUDE_MODEL || true)"
  if [ -z "$model" ]; then model=claude-3-5-sonnet-latest; fi
else
  model="$(printenv OPENAI_MODEL || true)"
  if [ -z "$model" ]; then model=gpt-5.5; fi
fi
token="$(printenv API_TOKEN || true)"
if [ -z "$token" ] && [ "$provider" = "claude" ]; then token="$(printenv ANTHROPIC_API_KEY || true)"; fi
if [ -z "$token" ] && [ "$provider" = "openai" ]; then token="$(printenv OPENAI_API_KEY || true)"; fi

project_name="Constructor Fabric Workspace"
slug="constructor-fabric-workspace"
root="/root/workspaces/$slug"
mkdir -p "$root"
cat > "$root/.constructor-fabric.json" <<JSON
{
  "provider": "$provider",
  "model": "$model",
  "api_token_set": $(if [ -n "$token" ]; then echo true; else echo false; fi),
  "source": "Virtuozzo install form",
  "trainer": "Electron"
}
JSON
{
  echo "LLM_PROVIDER=$provider"
  echo "OPENAI_MODEL=$model"
  echo "CLAUDE_MODEL=$model"
  if [ -n "$token" ]; then
    echo "API_TOKEN=$token"
    if [ "$provider" = "claude" ]; then echo "ANTHROPIC_API_KEY=$token"; else echo "OPENAI_API_KEY=$token"; fi
  fi
} > "$root/.env.constructor-fabric"
cat > "$root/CONSTRUCTOR_FABRIC_PROMPTS.md" <<'PROMPTS'
# Constructor Fabric copy/paste prompts

Use these prompts in any generated integration: VS Code/Copilot, Cursor, Windsurf, Codex, or Claude Code.

```text
/cf-constructor Create a PRD for a lightweight team task manager with projects, tasks, comments, notifications, and a REST API. Include target users, product goals, core user journeys, non-goals, constraints, success metrics, and acceptance criteria.
```

```text
/cf-constructor Decompose the PRD into feature artifacts. For each feature include user value, acceptance criteria, dependencies, risks, and traceability back to the PRD goals.
```

```text
/cf-constructor Create an implementation task backlog for these features. Each task must include intent, expected files or modules, test requirements, completion criteria, dependencies, and traceability to the PRD and feature acceptance criteria.
```

```text
/cf-constructor Produce implementation plans for the task backlog. Include sequencing, milestones, tests, risks, rollback notes, review checkpoints, and validation commands.
```

```text
/cf-constructor Review the generated Constructor Fabric artifacts as a PRD -> features -> tasks -> plans tree. Identify any missing links, weak acceptance criteria, duplicate tasks, or gaps that should be fixed before validation.
```

```text
/cf-constructor Fix any validation or traceability issues reported by cfc validate, then summarize the final PRD -> features -> tasks -> plans structure and the remaining implementation risks.
```
PROMPTS
if [ ! -f "$root/README.md" ]; then
  cat > "$root/README.md" <<README
# Constructor Fabric Workspace

This workspace was initialized automatically from the marketplace installation form.

- Provider: $provider
- Model: $model
- API token configured: $(if [ -n "$token" ]; then echo yes; else echo no; fi)

Open the Electron Trainer popup for the step-by-step guide, then use the generated
/cf-constructor workflow in your selected IDE or agent chat.
README
fi

if [ ! -d "$root/.cf-constructor" ]; then
  printf 'd\n' | cfc init --no-cache --project-root "$root" --install-dir .cf-constructor --project-name "$slug" --force
else
  printf 'd\n' | cfc init --no-cache --project-root "$root" --install-dir .cf-constructor --project-name "$slug" --force
fi
cfc generate-agents --root "$root" -y
(cd "$root" && cfc agents --json > /root/cyber-constructor/workspace-agents.json && python3 - <<'PYAGENTS'
import json, sys
text=json.dumps(json.load(open('/root/cyber-constructor/workspace-agents.json'))).lower()
required=['windsurf','cursor','claude','copilot','openai']
missing=[name for name in required if name not in text]
if missing:
    raise SystemExit('Missing generated IDE/agent integrations: '+', '.join(missing))
print('Generated Constructor Fabric integrations for: '+', '.join(required))
PYAGENTS
)
(cd "$root" && cfc validate --json) || true
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Constructor Fabric auto-bootstrap finished for $root"
CFCAUTO

cat > /root/cyber-constructor/run-cfc.sh <<'CFCRUN'
#!/bin/bash
export HOME=/root
export PATH=/root/cyber-constructor/.venv/bin:/root/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
exec /root/cyber-constructor/auto-bootstrap.sh
CFCRUN

mkdir -p /root/constructor-fabric/trainer
cat > /root/constructor-fabric/trainer/package.json <<'PKG'
{"name":"constructor-fabric-trainer","version":"1.0.0","main":"main.js","private":true,"description":"Constructor Fabric Electron Trainer"}
PKG
cat > /root/constructor-fabric/trainer/main.js <<'MAINJS'
const { app, BrowserWindow, shell } = require('electron');
const path = require('path');
app.commandLine.appendSwitch('no-sandbox');
function createWindow() {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    minWidth: 860,
    minHeight: 600,
    x: 260,
    y: 120,
    title: 'Constructor Fabric Trainer',
    backgroundColor: '#07111f',
    webPreferences: { nodeIntegration: false, contextIsolation: true }
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}
app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
MAINJS
cat > /root/constructor-fabric/trainer/index.html <<'HTMLTRAINER'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Constructor Fabric Showcase Guideline</title>
  <style>
    :root{color-scheme:dark;--bg:#07111f;--panel:#0d1b2f;--panel2:#101f36;--text:#eef6ff;--muted:#9fb3c8;--accent:#2dd4bf;--accent2:#60a5fa;--ok:#34d399;--gold:#f7c873}
    *{box-sizing:border-box} body{margin:0;background:radial-gradient(circle at 18% 0%,#173b6c 0,#07111f 42%,#040914 100%);color:var(--text);font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    .app{display:grid;grid-template-columns:310px 1fr;min-height:100vh}.side{padding:28px 22px;background:rgba(4,10,20,.76);border-right:1px solid rgba(255,255,255,.08)}
    .brand{display:flex;gap:14px;align-items:center;margin-bottom:24px}.logo{width:50px;height:50px;border-radius:16px;background:linear-gradient(135deg,var(--accent),var(--accent2));display:grid;place-items:center;font-weight:900;color:#04111f;box-shadow:0 14px 36px rgba(45,212,191,.18)}.brand h1{font-size:19px;margin:0}.brand p{margin:3px 0 0;color:var(--muted);font-size:13px}
    .step{display:flex;gap:12px;padding:12px 11px;margin:7px 0;border-radius:14px;color:var(--muted);cursor:pointer;border:1px solid transparent}.step.active{background:rgba(45,212,191,.12);border-color:rgba(45,212,191,.35);color:var(--text)}.num{width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:#14243c;color:#cce4ff;font-weight:800}.step.active .num{background:var(--accent);color:#05201d}.step b{display:block;font-size:14px}.step span{font-size:12px}
    .main{padding:32px 38px}.card{background:linear-gradient(180deg,rgba(16,31,54,.94),rgba(8,18,34,.94));border:1px solid rgba(255,255,255,.10);border-radius:26px;padding:30px;box-shadow:0 24px 70px rgba(0,0,0,.38);min-height:610px}.pill{display:inline-flex;align-items:center;gap:8px;border:1px solid rgba(45,212,191,.35);color:#9ff5e9;background:rgba(45,212,191,.09);border-radius:999px;padding:8px 12px;font-size:13px}.status-dot{width:8px;height:8px;background:var(--ok);border-radius:99px;box-shadow:0 0 14px var(--ok)}
    h2{font-size:34px;line-height:1.1;margin:20px 0 12px}.lead{font-size:17px;color:#c9d8e8;line-height:1.62;max-width:850px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin:22px 0}.box{background:rgba(255,255,255,.048);border:1px solid rgba(255,255,255,.09);border-radius:17px;padding:16px}.box b{display:block;margin-bottom:8px;color:#fff}.box p,.box li{color:var(--muted);line-height:1.55;margin:0}.quote{border-left:3px solid var(--accent);background:rgba(45,212,191,.075);padding:14px 16px;border-radius:12px;color:#dffdf8;line-height:1.55;margin-top:18px}.code,.prompt-text{font-family:"SFMono-Regular",Consolas,monospace;background:#0a1220;border:1px solid rgba(255,255,255,.11);border-radius:12px;padding:12px;color:#d7ecff;white-space:pre-wrap}.prompt{margin-top:18px}.prompt-head{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:8px}.prompt-head b{color:#fff}.prompt-head span{color:var(--muted);font-size:12px}.prompt-text{width:100%;min-height:118px;resize:none;outline:0;background:#111827;color:#cbd5e1;border-color:#334155;box-shadow:inset 0 0 0 1px rgba(0,0,0,.25);cursor:text}.prompt-text[readonly]{user-select:text;-webkit-user-select:text}.copy-ok{color:#9ff5e9;font-size:12px;margin-left:10px}.buttons{display:flex;gap:12px;align-items:center;margin-top:24px}.btn{border:0;border-radius:13px;padding:12px 16px;font-weight:800;cursor:pointer}.primary{background:linear-gradient(135deg,var(--accent),var(--accent2));color:#02111f}.secondary{background:#172944;color:#d8e9ff;border:1px solid rgba(255,255,255,.10)}.foot{margin-top:18px;color:var(--muted);font-size:13px}.accent{color:var(--gold)}
  </style>
</head>
<body>
  <div class="app"><aside class="side"><div class="brand"><div class="logo">CF</div><div><h1>Constructor Fabric</h1><p>Showcase Guideline</p></div></div><div id="nav"></div></aside><main class="main"><section class="card"><div class="pill"><span class="status-dot"></span><span id="configPill">Ready for the guided showcase</span></div><div id="content"></div><div class="buttons"><button class="btn secondary" id="prev">Back</button><button class="btn primary" id="next">Next step</button></div><div class="foot" id="foot"></div></section></main></div>
  <script>
  const steps = [
    {t:'Welcome',s:'Showcase path',h:'Welcome to Constructor Fabric Showcase Guideline',body:'We will go through the basic Constructor Fabric flow: turn a product idea into a structured product brief, decompose it into features and tasks, create implementation-ready artifacts, validate traceability, and finish with a reviewable project workspace.',boxes:[['What you will build','A small, realistic product plan with PRD, feature decomposition, task backlog, implementation plan, and validation report.'],['Where to paste prompts','Open any generated integration: VS Code/Copilot, Cursor, Windsurf, Codex, or Claude Code. Copy the prompt from this guide and paste it into the IDE or agent chat.']],quote:'Suggested showcase idea: “Build a lightweight team task manager with projects, tasks, comments, status workflow, notifications, and a simple REST API.”'},
    {t:'Product brief',s:'Idea → PRD',h:'Start with a clear product story',body:'Ask the agent to create a concise PRD from the idea. The goal is to capture users, goals, core scenarios, constraints, and success criteria before jumping into implementation.',boxes:[['Expected artifact','A PRD or product brief that explains who the product is for, what problem it solves, and what “done” looks like.'],['Works in every IDE','Paste the same prompt into Cursor, Windsurf, VS Code/Copilot, Codex, or Claude Code. The generated Constructor Fabric agents are prepared for all of them.']],prompt:'/cf-constructor Create a PRD for a lightweight team task manager with projects, tasks, comments, notifications, and a REST API. Include target users, product goals, core user journeys, non-goals, constraints, success metrics, and acceptance criteria.'},
    {t:'Features',s:'PRD → scope',h:'Decompose the product into features',body:'Next, split the PRD into a small set of features. Each feature should have clear value, acceptance criteria, dependencies, and a traceable link back to the product goals.',boxes:[['Feature examples','Authentication, project workspace, task workflow, comments, notifications, API surface, and audit/history.'],['Copy/paste flow','Use the Copy prompt button, switch to your selected IDE or agent chat, paste, and send.']],prompt:'/cf-constructor Decompose the PRD into feature artifacts. For each feature include user value, acceptance criteria, dependencies, risks, and traceability back to the PRD goals.'},
    {t:'Tasks',s:'Features → backlog',h:'Turn features into implementation tasks',body:'For each feature, ask Constructor Fabric to produce engineering tasks that are small enough to execute and review. Tasks should include intent, expected files or modules, tests, and completion criteria.',boxes:[['Task examples','Create project data model, implement task status transitions, add comments endpoint, add notification event contract, write validation tests.'],['Quality bar','Each task should be independently reviewable and traceable to a feature and PRD goal.']],prompt:'/cf-constructor Create an implementation task backlog for these features. Each task must include intent, expected files or modules, test requirements, completion criteria, dependencies, and traceability to the PRD and feature acceptance criteria.'},
    {t:'Plans',s:'Backlog → execution',h:'Create implementation-ready plans',body:'Now convert the backlog into an execution plan. A good plan explains sequencing, risks, test strategy, and review checkpoints so another agent or engineer can implement safely.',boxes:[['Expected artifact','A sequenced implementation plan with milestones, quality gates, and validation steps.'],['Ready for handoff','The output should be specific enough that another IDE agent can implement from it without guessing.']],prompt:'/cf-constructor Produce implementation plans for the task backlog. Include sequencing, milestones, tests, risks, rollback notes, review checkpoints, and validation commands.'},
    {t:'Artifacts',s:'Generate outputs',h:'Generate and inspect the artifacts',body:'Use the selected AI agent to create the actual Constructor Fabric artifacts in the workspace. Review the result as a product tree: PRD → features → tasks → plans. The showcase should demonstrate that every lower-level item traces back to a higher-level decision.',boxes:[['What to inspect','Open the generated artifacts, check naming, traceability IDs, acceptance criteria, and task completeness.'],['Quality signal','The workspace should read like a complete product decomposition, not a random collection of notes.']],prompt:'/cf-constructor Review the generated Constructor Fabric artifacts as a PRD → features → tasks → plans tree. Identify any missing links, weak acceptance criteria, duplicate tasks, or gaps that should be fixed before validation.'},
    {t:'Validate',s:'Traceability',h:'Validate the complete flow',body:'Finish by running the deterministic checks from the workspace root. Validation proves that the artifacts are discoverable, linked, and ready for the next implementation stage.',code:'cd /root/workspaces/constructor-fabric-workspace\ncfc validate\ncfc list-ids\ncfc toc',boxes:[['Success criteria','Validation passes, IDs are listed, and the table of contents shows a coherent PRD → features → tasks → plans flow.'],['Optional final step','Create a local commit only after the artifacts are validated and reviewed.']],prompt:'/cf-constructor Fix any validation or traceability issues reported by cfc validate, then summarize the final PRD → features → tasks → plans structure and the remaining implementation risks.'}
  ];
  let idx=0;
  function renderNav(){document.getElementById('nav').innerHTML=steps.map((x,i)=>'<div class="step '+(i===idx?'active':'')+'" data-i="'+i+'"><div class="num">'+(i+1)+'</div><div><b>'+x.t+'</b><span>'+x.s+'</span></div></div>').join('');document.querySelectorAll('.step').forEach(e=>e.onclick=()=>{idx=Number(e.dataset.i);render();});}
  function esc(v){return String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
  function render(){renderNav();const x=steps[idx];let html='<h2>'+esc(x.h)+'</h2><p class="lead">'+esc(x.body)+'</p>';if(x.quote){html+='<div class="quote">'+esc(x.quote)+'</div>';}if(x.boxes){html+='<div class="grid">'+x.boxes.map(b=>'<div class="box"><b>'+esc(b[0])+'</b><p>'+esc(b[1])+'</p></div>').join('')+'</div>';}if(x.prompt){html+='<div class="prompt"><div class="prompt-head"><div><b>Prompt to copy into IDE</b><br><span>Copy this text, paste it into Cursor, Windsurf, VS Code/Copilot, Codex, or Claude Code, then send.</span></div><button class="btn secondary" id="copyPrompt" title="Copy prompt to clipboard">⧉ Copy prompt</button></div><textarea class="prompt-text" id="promptText" readonly spellcheck="false" aria-label="Prompt text to copy">'+esc(x.prompt)+'</textarea><span class="copy-ok" id="copyStatus"></span></div>';}if(x.code){html+='<div class="code">'+esc(x.code)+'</div>';}document.getElementById('content').innerHTML=html;const copy=document.getElementById('copyPrompt');if(copy){copy.onclick=async()=>{const ta=document.getElementById('promptText');ta.focus();ta.select();let ok=false;try{if(navigator.clipboard&&navigator.clipboard.writeText){await navigator.clipboard.writeText(ta.value);ok=true;}}catch(e){}if(!ok){try{ok=document.execCommand('copy');}catch(e){ok=false;}}document.getElementById('copyStatus').textContent=ok?'Copied to clipboard.':'Selected — press Ctrl+C, then paste into your IDE.';};}document.getElementById('prev').disabled=idx===0;document.getElementById('next').textContent=idx===steps.length-1?'Finish showcase':'Next step';document.getElementById('foot').textContent='Step '+(idx+1)+' of '+steps.length+' — Constructor Fabric basic flow showcase';document.getElementById('configPill').textContent='All IDE/agent integrations are generated: VS Code/Copilot, Cursor, Windsurf, Codex, Claude';}
  document.getElementById('prev').onclick=()=>{if(idx>0){idx--;render();}};document.getElementById('next').onclick=()=>{if(idx<steps.length-1){idx++;render();}else{window.close();}};render();
  </script>
</body>
</html>
HTMLTRAINER
cat > /root/constructor-fabric/run-trainer.sh <<'RUNTRAINER'
#!/bin/sh
set -u
export HOME=/root
export DISPLAY=:1
export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH
LOG=/root/constructor-fabric/electron-trainer.log
if ! command -v electron >/dev/null 2>&1; then
  if [ -x /opt/node-current/bin/npm ]; then
    /opt/node-current/bin/npm install -g electron@latest >>"$LOG" 2>&1 || true
  fi
fi
if command -v electron >/dev/null 2>&1 && electron --no-sandbox --version >>"$LOG" 2>&1; then
  exec electron --no-sandbox /root/constructor-fabric/trainer
fi
echo "Electron is required for the Constructor Fabric Trainer but is not available or failed to start." >&2
exit 1
RUNTRAINER
chmod +x /root/cyber-constructor/auto-bootstrap.sh
chmod +x /root/cyber-constructor/run-cfc.sh
chmod +x /root/constructor-fabric/run-trainer.sh
mkdir -p /root/Desktop /root/.config/autostart
cat > /root/.config/autostart/constructor-fabric.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Constructor Fabric Trainer
Exec=sh -lc 'sleep 12; /root/constructor-fabric/run-trainer.sh || true'
X-GNOME-Autostart-enabled=true
DESK
cat > /root/Desktop/Constructor-Fabric-Trainer.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Constructor Fabric Trainer
Exec=/root/constructor-fabric/run-trainer.sh
Icon=/root/constructor-fabric/app/icon.png
Terminal=false
Categories=Development;
DESK
cat > /root/Desktop/Constructor-Fabric-Health.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Constructor Fabric Health
Exec=xdg-open http://127.0.0.1:8081/
Icon=/root/constructor-fabric/app/icon.png
Terminal=false
Categories=Development;
DESK
chmod +x /root/.config/autostart/constructor-fabric.desktop /root/Desktop/Constructor-Fabric-Trainer.desktop /root/Desktop/Constructor-Fabric-Health.desktop
cat > /root/Desktop/Cyber-Constructor.desktop <<'CFCDESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Constructor Fabric Workspace
Comment=Open the prepared showcase workspace
Exec=lxterminal --working-directory=/root/workspaces/constructor-fabric-workspace
Icon=/root/constructor-fabric/app/icon.png
Terminal=false
Categories=Development;
CFCDESK
chmod +x /root/Desktop/Cyber-Constructor.desktop
mkdir -p /root/constructor-fabric
cat > /root/constructor-fabric/open-agent.sh <<'OPENAGENT'
#!/bin/bash
agent="${1:-codex}"
export HOME=/root
export PATH=/root/cyber-constructor/.venv/bin:/root/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
workspace=/root/workspaces/constructor-fabric-workspace
mkdir -p "$workspace"
cd "$workspace"
if [ -f .env.constructor-fabric ]; then
  set -a
  . ./.env.constructor-fabric 2>/dev/null || true
  set +a
fi
provider="$(python3 - <<'PYCFG' 2>/dev/null || true
import json, pathlib
p=pathlib.Path('.constructor-fabric.json')
if p.exists():
    print(json.loads(p.read_text()).get('provider',''))
PYCFG
)"
existing_openai_key="$(printenv OPENAI_API_KEY || true)"
existing_anthropic_key="$(printenv ANTHROPIC_API_KEY || true)"
install_api_token="$(printenv API_TOKEN || true)"
if [ -z "$existing_openai_key" ] && [ -n "$install_api_token" ]; then export OPENAI_API_KEY="$install_api_token"; fi
if [ -z "$existing_anthropic_key" ] && [ -n "$install_api_token" ]; then export ANTHROPIC_API_KEY="$install_api_token"; fi
clear
cat <<'WELCOME'
Constructor Fabric Showcase

Use this agent to drive the product flow with the generated /cf-constructor workflow.

The Electron Trainer has a Copy prompt button on every step.
The same copy/paste prompts are also saved here:
  CONSTRUCTOR_FABRIC_PROMPTS.md

Open that file, copy a prompt, paste it into this agent chat, and send.
The generated integrations are prepared for VS Code/Copilot, Cursor, Windsurf, Codex, and Claude Code.

After the agent finishes, validate from this workspace with:
cfc validate && cfc list-ids && cfc toc
WELCOME
echo
echo "Workspace: $workspace"
echo
case "$agent" in
  claude)
    if command -v claude >/dev/null 2>&1; then
      echo "Starting Claude Code..."
      exec claude
    fi
    echo "Claude Code is not ready yet. Please retry this desktop shortcut in a minute."
    ;;
  codex|*)
    if command -v codex >/dev/null 2>&1; then
      echo "Starting OpenAI Codex..."
      exec codex
    fi
    echo "OpenAI Codex is not ready yet. Please retry this desktop shortcut in a minute."
    ;;
esac
echo
read -r -p "Press Enter to close."
OPENAGENT
chmod +x /root/constructor-fabric/open-agent.sh
cfc --version
cfc validate --json
