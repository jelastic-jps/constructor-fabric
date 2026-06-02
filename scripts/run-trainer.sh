        #!/bin/sh
        set -u
        export HOME="${HOME:-/home/developer}"
        export DISPLAY=:1
        export PATH=/opt/node-current/bin:/usr/local/bin:/usr/bin:/bin:$PATH
        LOG="${HOME}/constructor-fabric/electron-trainer.log"
        if ! command -v electron >/dev/null 2>&1; then
          if [ -x /opt/node-current/bin/npm ]; then
            /opt/node-current/bin/npm install -g electron >>"$LOG" 2>&1 || true
          fi
        fi
        if command -v electron >/dev/null 2>&1; then
          exec electron --no-sandbox ${HOME}/constructor-fabric/trainer
        fi
        exec xdg-open http://127.0.0.1:8081/
