        #!/bin/bash
        agent="${1:-codex}"
        export HOME=/root
        export PATH=${HOME}/cyber-constructor/.venv/bin:${HOME}/.local/bin:/usr/local/bin:/opt/node-current/bin:$PATH
        workspace=${HOME}/workspaces/constructor-fabric-workspace
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
