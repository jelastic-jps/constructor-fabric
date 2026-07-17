#!/bin/sh
set -eu
export HOME="${HOME:-/home/developer}"
export PATH="${HOME}/.local/bin:/usr/local/bin:$PATH"
STUDIO_REPO="constructorfabric/studio"
STUDIO_DIR="${HOME}/studio"
mkdir -p "${HOME}/.cf-studio/cache" "${HOME}/studio-install"
cd "${HOME}/studio-install"
# Resolve the latest published Constructor Studio release tag via the
# /releases/latest redirect (no GitHub API rate limits, no JSON parsing).
# Set STUDIO_VERSION=vX.Y.Z to pin a specific release instead.
STUDIO_VERSION="${STUDIO_VERSION:-latest}"
if [ "$STUDIO_VERSION" = "latest" ]; then
  echo "Resolving latest Constructor Studio release"
  STUDIO_VERSION="$(curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${STUDIO_REPO}/releases/latest" | sed 's|.*/tag/||')"
fi
case "$STUDIO_VERSION" in
  v[0-9]*) ;;
  *) echo "Failed to resolve Constructor Studio release (got: '${STUDIO_VERSION}')" >&2; exit 1 ;;
esac
echo "Fetching Constructor Studio ${STUDIO_VERSION} source archive"
curl --noproxy '*' --retry 3 --retry-delay 2 --retry-connrefused -fsSL "https://github.com/${STUDIO_REPO}/archive/refs/tags/${STUDIO_VERSION}.tar.gz" -o studio.tar.gz
rm -rf "$STUDIO_DIR"
mkdir -p "$STUDIO_DIR"
tar -xzf studio.tar.gz --strip-components=1 -C "$STUDIO_DIR"
find "$STUDIO_DIR" \( -name '._*' -o -name '.DS_Store' \) -delete
if [ ! -x "${HOME}/.local/bin/uv" ]; then
  wget -q https://astral.sh/uv/install.sh -O "${HOME}/install-uv.sh"
  sh "${HOME}/install-uv.sh" >"${HOME}/studio-install/uv-install.log" 2>&1
fi
"${HOME}/.local/bin/uv" python install 3.11 >"${HOME}/studio-install/uv-python311.log" 2>&1
cd "$STUDIO_DIR"
"${HOME}/.local/bin/uv" venv --python 3.11 "$STUDIO_DIR/.venv" >"${HOME}/studio-install/venv.log" 2>&1
# Studio derives its package version from git metadata (setuptools-scm); a
# source tarball has none, so pass the version we resolved explicitly.
SETUPTOOLS_SCM_PRETEND_VERSION="${STUDIO_VERSION#v}" "${HOME}/.local/bin/uv" pip install --python "$STUDIO_DIR/.venv/bin/python" -e "$STUDIO_DIR" >"${HOME}/studio-install/pip-install.log" 2>&1
ln -sf "$STUDIO_DIR/.venv/bin/cfs" "${HOME}/.local/bin/cfs"
ln -sf "$STUDIO_DIR/.venv/bin/constructor-studio" "${HOME}/.local/bin/constructor-studio"
# Remove the legacy pinned install left by older images (superseded by ${STUDIO_DIR})
rm -rf "${HOME}/cyber-constructor" "${HOME}/.cf-constructor" "${HOME}/cfc-install"
rm -rf "${HOME}/.cf-studio/cache"
# Seed the global skill-engine cache using Studio's supported local-seed path
# (per studio CONTRIBUTING.md, `make update` = `cfs update --source . --force`).
# This copies the full source tree AND writes the cache markers Studio expects
# (.version, .provenance.json, version.toml); the "local_path" provenance is
# what stops later `cfs update` runs from silently re-downloading over it.
# On a fresh install the trailing "update project" phase exits non-zero (no
# project exists yet) — the cache is written before that, so verify the cache
# explicitly instead of trusting the exit code.
cfs update --source "$STUDIO_DIR" --force || true
for d in skills workflows requirements schemas architecture; do
  if [ ! -d "${HOME}/.cf-studio/cache/$d" ]; then
    echo "Constructor Studio cache seeding failed: missing cache/$d" >&2
    exit 1
  fi
done
if [ ! -f "${HOME}/.cf-studio/cache/.provenance.json" ]; then
  echo "Constructor Studio cache seeding failed: missing .provenance.json" >&2
  exit 1
fi
cfs init --no-cache --project-root "$STUDIO_DIR" --install-dir .cf-studio --project-name studio --force --yes >"${HOME}/studio-install/init.log" 2>&1
cfs generate-agents --root "$STUDIO_DIR" -y >"${HOME}/studio-install/generate-agents.log" 2>&1
# The workspace auto-bootstrap script (scripts/auto-bootstrap.sh) is placed
# at ${HOME}/studio/auto-bootstrap.sh by bootstrap.sh — single source of truth.

mkdir -p "${HOME}/constructor-fabric/app"
if [ -f "${HOME}/constructor-fabric/assets/constructor-fabric-logo.png" ]; then
  cp "${HOME}/constructor-fabric/assets/constructor-fabric-logo.png" "${HOME}/constructor-fabric/app/icon.png" 2>/dev/null || true
fi
mkdir -p "${HOME}/constructor-fabric"
cat > "${HOME}/constructor-fabric/open-agent.sh" <<'OPENAGENT'
#!/bin/bash
agent="${1:-codex}"
export HOME="${HOME:-/home/developer}"
export PATH="${HOME}/studio/.venv/bin:${HOME}/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH"
workspace="${HOME}/workspaces/constructor-fabric-workspace"
mkdir -p "$workspace"
cd "$workspace"
clear
cat <<'WELCOME'
Constructor Fabric — Constructor Studio workspace

This terminal agent shares the same workspace as the in-IDE Trainer.
The Trainer panel inside code-server guides the full greenfield training;
reopen it any time: press F1 and run "Constructor Fabric: Open Trainer".

In an agent chat, type cf to activate Constructor Studio.
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
chmod +x "${HOME}/constructor-fabric/open-agent.sh"
cfs --version
cfs validate --json
