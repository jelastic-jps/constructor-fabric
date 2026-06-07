#!/bin/bash
# Run the original startup.sh as root first (for system setup)
sudo /startup.sh

# Start Constructor Fabric services on every container start.
# These are created by the JPS bootstrap (start-services.sh) on first install
# and persist in the container filesystem across restarts.
CF_HOME="${CF_HOME:-/home/developer}"
CF_WORKSPACE="${CF_HOME}/workspaces/constructor-fabric-workspace"
LOG_DIR="${CF_HOME}/constructor-fabric"
mkdir -p "$LOG_DIR"

# Ensure nginx has the Constructor Fabric config and start it
if [ -f /etc/nginx/sites-enabled/default ]; then
  NGINX_BIN="$(command -v nginx || echo /usr/sbin/nginx)"
  pkill -9 nginx 2>/dev/null || true
  sleep 1
  $NGINX_BIN -t 2>/dev/null && $NGINX_BIN 2>/dev/null || service nginx start 2>/dev/null || true
fi

# Start code-server if installed and not already running
if command -v code-server >/dev/null 2>&1; then
  if ! pgrep -f "code-server --bind-addr" >/dev/null 2>&1; then
    # Ensure supervisor config exists
    if [ -f /etc/supervisor/conf.d/code-server.conf ]; then
      supervisorctl reread 2>/dev/null || true
      supervisorctl update 2>/dev/null || true
      supervisorctl start code-server 2>/dev/null || true
    else
      # Start directly if no supervisor config
      sudo -u developer -H code-server --bind-addr 0.0.0.0:8080 --auth none --disable-telemetry "$CF_WORKSPACE" > "$LOG_DIR/code-server.log" 2>&1 &
    fi
  fi
fi

# Start trainer HTTP server if directory exists
if [ -d "$CF_WORKSPACE/trainer" ]; then
  if ! pgrep -f "http.server 8082" >/dev/null 2>&1; then
    if [ -f /etc/supervisor/conf.d/trainer.conf ]; then
      supervisorctl start trainer 2>/dev/null || true
    else
      sudo -u developer -H python3 -m http.server 8082 --directory "$CF_WORKSPACE/trainer" --bind 0.0.0.0 > "$LOG_DIR/trainer-http.log" 2>&1 &
    fi
  fi
fi

# Start app server
if [ -f "${CF_HOME}/constructor-fabric/app/server.py" ]; then
  if ! pgrep -f "app/server.py" >/dev/null 2>&1; then
    python3 "${CF_HOME}/constructor-fabric/app/server.py" > "$LOG_DIR/app.log" 2>&1 &
  fi
fi

# Then run any commands as the developer user
exec "$@"
