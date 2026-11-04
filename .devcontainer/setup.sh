#!/usr/bin/env bash
# OpenDuet Codespace bootstrap. Safe to rerun.
# Logs: /tmp/openduet-setup.log (this script), /tmp/openduet-start.log (the stack)
set -uo pipefail
LOG=/tmp/openduet-setup.log
log(){ echo "[setup $(date +%T)] $*" >> "$LOG"; }

cd /workspaces/OpenDuet 2>/dev/null || cd "$(pwd)"

# 1. Wait for docker-in-docker
for i in $(seq 1 90); do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker info >/dev/null 2>&1 || log "WARN docker not ready yet"

# 2. Write .env once (secrets come from Codespace secrets injected as env vars)
if [ ! -f .env ]; then
  cat > .env <<'ENVEOF'
DATABASE_URL=postgres://openbot:openbot@localhost:5432/openbot
KEY_ENCRYPTION_KEY=PLACEHOLDER_TO_BE_REPLACED
PORT=3001
SERVER_PORT=3001
TENANT_PACKAGE_DIR=../examples/openduet
COMPOSE_PROJECT_NAME=openduet
SERVER_IMAGE=openduet-server:latest
COMPUTER_IMAGE=openduet-agent-computer:latest
SUPERVISOR_IMAGE=openduet-supervisor:latest
BOT_IMAGE=openduet-agent-bot:latest
LANGGRAPH_IMAGE=openduet-agent-langgraph:latest
OPENBOT_SINGLE_USER=true
OPENBOT_PUBLIC_URL=https://CHANGE_ME-3001.app.github.dev
OPENBOT_APP_URL=https://CHANGE_ME-3010.app.github.dev
TRUSTED_ORIGINS=https://CHANGE_ME-3010.app.github.dev
INTELLIGENCE_API_URL=https://api.intelligence.copilotkit.ai
INTELLIGENCE_GATEWAY_WS_URL=wss://realtime.intelligence.copilotkit.ai
AGENT_STALL_TIMEOUT_MS=60000
OPENAI_BASE_URL=https://open.bigmodel.cn/api/paas/v4
BOT_MODEL=glm-4.7
AGENT_BOT_MODEL=glm-4.7
AGENT_COMPUTER_URL=http://localhost:4100
COMPUTER_TOKEN=
COMPUTER_SUPERVISOR_URL=
SUPERVISOR_TOKEN=
COMPUTER_RUNTIME=
AGENT_TOOL_TOKEN=
WORKER_SHARED_SECRET=
MANAGED_AGENT_TOKEN=
ENVEOF
  ok=true
  for k in OPENAI_API_KEY INTELLIGENCE_API_KEY CPK_INTELLIGENCE_API_KEY CPK_TELEMETRY_ID; do
    v="${!k:-}"
    if [ -n "$v" ]; then
      printf '%s=%s\n' "$k" "$v" >> .env
    else
      ok=false; log "WARN missing Codespace secret: $k"
    fi
  done
  $ok || log "WARN some secrets missing; server may refuse to start"
  sed -i "s|^KEY_ENCRYPTION_KEY=.*|KEY_ENCRYPTION_KEY=$(openssl rand -base64 32)|" .env
  chmod 600 .env
fi

# 3. Point public URLs at this Codespace
if [ -n "${CODESPACE_NAME:-}" ]; then
  sed -i "s/CHANGE_ME/$CODESPACE_NAME/g" .env
fi

# 4. Tenant model
sed -i 's/default_model:.*/default_model: glm-4.7/' openbot/examples/openduet/model.yaml 2>/dev/null || true

# 5. Let Vite serve the forwarded *.app.github.dev host
grep -q allowedHosts openbot/app/vite.config.ts || \
  sed -i 's/strictPort: true,/strictPort: true, allowedHosts: true,/' openbot/app/vite.config.ts

# 6. Install bun if absent
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash >> "$LOG" 2>&1
  export PATH="$HOME/.bun/bin:$PATH"
fi

# 7. Make ports public (best effort; devcontainer portsAttributes also does this)
if command -v gh >/dev/null 2>&1 && [ -n "${CODESPACE_NAME:-}" ]; then
  gh codespace ports visibility 3010:public 3001:public -c "$CODESPACE_NAME" >/dev/null 2>&1 || true
fi

# 8. Launch the stack in the background
nohup bash scripts/start.sh > /tmp/openduet-start.log 2>&1 &
log "launched start.sh pid $!"
log "done"
