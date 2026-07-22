#!/bin/sh
# Deploy-time AI coding agent selection (runs as developer, idempotent).
#
# Reads the install-form choice from ~/.cf-coding-agent (written by the JPS
# manifest; file transport because su/sudo transitions drop container env).
# Values: claude (form default) | codex | copilot. A missing or invalid file
# falls back to copilot: if the choice ever fails to reach the container, the
# environment still has the built-in agent to work with.
#
# For claude/codex the built-in GitHub Copilot is removed from THIS
# environment only — the image keeps it on purpose, so a future
# "keep GitHub Copilot" option remains a one-word change.
set -eu

export HOME="${HOME:-/home/developer}"
export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH

AGENT="$(cat "${HOME}/.cf-coding-agent" 2>/dev/null | tr -d '[:space:]' || true)"
case "$AGENT" in claude|codex|copilot) ;; *) AGENT=copilot ;; esac
echo "[coding-agent] selected agent: $AGENT"

if [ "$AGENT" = "copilot" ]; then
  echo "[coding-agent] keeping the built-in GitHub Copilot"
  exit 0
fi

case "$AGENT" in
  claude)
    CLI_PKG="@anthropic-ai/claude-code"; CLI_BIN="claude"; EXT_ID="anthropic.claude-code" ;;
  codex)
    CLI_PKG="@openai/codex"; CLI_BIN="codex"; EXT_ID="openai.chatgpt" ;;
esac

# Remove the built-in Copilot from this environment (deploy-time, not build-time).
sudo rm -rf /usr/local/lib/vscode/extensions/copilot*

# CLI: install once; first run happens as developer so the agent's home
# directory (~/.claude, ~/.codex) is created with the right owner.
if ! command -v "$CLI_BIN" >/dev/null 2>&1; then
  n=0
  until sudo env PATH="$PATH" npm install -g "$CLI_PKG" >/tmp/npm-agent.log 2>&1; do
    n=$((n + 1)); [ "$n" -ge 3 ] && { echo "[coding-agent] npm install failed"; tail -5 /tmp/npm-agent.log; exit 1; }
    sleep 3
  done
fi
"$CLI_BIN" --version >/dev/null 2>&1 || true
echo "[coding-agent] CLI ready: $("$CLI_BIN" --version 2>/dev/null | head -1)"

# IDE extension from Open VSX; skip if already installed (restart path).
if ! code-server --list-extensions 2>/dev/null | grep -qx "$EXT_ID"; then
  n=0
  until code-server --install-extension "$EXT_ID" >/tmp/ext-agent.log 2>&1; do
    n=$((n + 1)); [ "$n" -ge 3 ] && { echo "[coding-agent] extension install failed"; tail -5 /tmp/ext-agent.log; exit 1; }
    sleep 3
  done
fi
echo "[coding-agent] extension ready: $EXT_ID"
