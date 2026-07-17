#!/bin/bash
set -euo pipefail
export HOME="${HOME:-/home/developer}"
export PATH="${HOME}/studio/.venv/bin:${HOME}/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH"
LOG="${HOME}/studio/auto-bootstrap.log"
exec >>"$LOG" 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Constructor Fabric auto-bootstrap started"

# No provider/model/API-key provisioning: the chat agent (GitHub Copilot)
# authenticates with the trainee's GitHub account, and the model is picked in
# the chat UI (Auto / Manage Models) — taught by Trainer step 2.
slug="constructor-fabric-workspace"
root="${HOME}/workspaces/$slug"
mkdir -p "$root"
cat > "$root/.constructor-fabric.json" <<JSON
{
  "source": "Virtuozzo marketplace install",
  "trainer": "code-server-webview"
}
JSON
# The Trainer webview is the single source of training content; remove the
# legacy copy/paste prompt file from older images so it cannot drift.
rm -f "$root/CONSTRUCTOR_FABRIC_PROMPTS.md"
if [ ! -f "$root/README.md" ]; then
  cat > "$root/README.md" <<README
# Constructor Fabric Workspace

This workspace was initialized automatically by the marketplace installation.

The Constructor Fabric Trainer opens automatically inside the IDE and guides you
step by step. To reopen it: press F1 and run "Constructor Fabric: Open Trainer".

The AI chat agent (GitHub Copilot Chat) signs in with your GitHub account. Pick
a model with the Auto selector in the chat input; your own Anthropic or OpenAI
API key can be added there via Manage Models.
README
fi

cfs init --no-cache --project-root "$root" --install-dir .cf-studio --project-name "$slug" --force --yes
# init --force backs up the build-time .cf-studio before re-initializing; the
# backup only holds generated state and would litter every fresh workspace.
rm -rf "$root"/.cf-studio.*.backup
cfs generate-agents --root "$root" -y
(cd "$root" && cfs agents --json > "${HOME}/studio/workspace-agents.json" && python3 - <<'PYAGENTS'
import json, sys
from pathlib import Path
text=json.dumps(json.loads((Path.home()/'studio/workspace-agents.json').read_text())).lower()
required=['windsurf','claude','copilot','openai']
missing=[name for name in required if name not in text]
if missing:
    raise SystemExit('Missing generated IDE/agent integrations: '+', '.join(missing))
print('Generated Constructor Fabric integrations for: '+', '.join(required))
PYAGENTS
)
# Final step of Studio deployment: refresh the Studio runtime and the installed
# kits to their latest published versions (kits are fetched from their registered
# GitHub sources). Non-fatal: the baked Studio/kit versions already work.
(cd "$root" && cfs update --with-kits yes --yes) \
  || echo "WARNING: cfs update --with-kits failed — continuing with baked Studio/kit versions"
(cd "$root" && cfs validate --json) || true
# Greenfield precondition: the trainee must start with an empty artifact tree.
# Only warn (never fail) — on redeploys the trainee may legitimately have work
# in progress, and the Trainer's own state tracks that.
if [ ! -f "$root/.constructor-fabric-trainer/state.json" ]; then
  for d in architecture src .cf-studio/artifacts; do
    if [ -e "$root/$d" ]; then
      echo "WARNING: fresh workspace already contains '$d/' — greenfield training expects it to be absent"
    fi
  done
fi
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Constructor Fabric auto-bootstrap finished for $root"
