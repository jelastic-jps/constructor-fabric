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
