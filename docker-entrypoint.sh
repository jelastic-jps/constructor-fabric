#!/bin/bash
set -euo pipefail

export HOME=${HOME:-/home/developer}
export USER=${USER:-developer}
export PATH=/opt/node-current/bin:/home/developer/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH
CF_WORKSPACE="${CF_WORKSPACE:-/home/developer/workspaces/constructor-fabric-workspace}"
LOG_DIR="/home/developer/constructor-fabric"
mkdir -p "$LOG_DIR" "$CF_WORKSPACE"
chown -R developer:developer /home/developer 2>/dev/null || true

if command -v supervisord >/dev/null 2>&1; then
  supervisord -c /etc/supervisor/supervisord.conf >"$LOG_DIR/supervisord.log" 2>&1 || true
fi

# If the JPS bootstrap has not created configs yet, create the plain code-server config now.
if [ -x /home/developer/constructor-fabric/scripts/start-services.sh ]; then
  sudo -u developer -H /home/developer/constructor-fabric/scripts/start-services.sh >"$LOG_DIR/start-services.log" 2>&1 || true
fi

if [ -f /etc/supervisor/conf.d/code-server.conf ]; then
  supervisorctl reread 2>/dev/null || true
  supervisorctl update 2>/dev/null || true
  supervisorctl start code-server 2>/dev/null || true
else
  sudo -u developer -H code-server --bind-addr 0.0.0.0:8080 --auth none --disable-telemetry "$CF_WORKSPACE" >"$LOG_DIR/code-server.log" 2>&1 &
fi


exec "$@"
