#!/usr/bin/env bash
# OpenDuet Codespace bootstrap. Idempotent; safe to rerun on every start.
# Everything it learns is written into the workspace, so it can be read without a terminal:
#   _STATUS.txt   short human-readable state
#   _setup.log    this script's log
#   _stack.log    the stack's stdout/stderr (docker compose build, bun, app)
set -uo pipefail
cd /workspaces/OpenDuet 2>/dev/null || cd "$(pwd)"
W="$(pwd -P)"
LOG="$W/_setup.log"
STACK="$W/_stack.log"
STATUS="$W/_STATUS.txt"
log(){ echo "[$(date +%T)] $*" | tee -a "$LOG"; }
status(){ echo "$*" >> "$STATUS"; }

: > "$STATUS"
log "setup start in $W"
status "setup started $(date)"

# ---------------------------------------------------------------------------
# 1. docker (docker-in-docker needs a while to come up on a fresh codespace)
# ---------------------------------------------------------------------------
ok=""
for i in $(seq 1 150); do
  if docker info >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ -n "$ok" ]; then
  log "docker ready"
  status "docker: ready"
else
  log "docker NOT ready after 300s"
  status "docker: NOT READY"
fi

# ---------------------------------------------------------------------------
# 2. .env  (secrets arrive as Codespace secrets, injected as environment vars)
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  log "writing .env"
  cat > .env <<'ENVEOF'
DATABASE_URL=postgres://openbot:openbot@localhost:5432/openbot
KEY_ENCRYPTION_KEY=REPLACE_ME
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
OPENBOT_PUBLIC_URL=https://NAME_ME-3001.app.github.dev
OPENBOT_APP_URL=https://NAME_ME-3010.app.github.dev
TRUSTED_ORIGINS=https://NAME_ME-3010.app.github.dev
INTELLIGENCE_API_URL=https://api.intelligence.copilotkit.ai
INTELLIGENCE_GATEWAY_WS_URL=wss://realtime.intelligence.copilotkit.ai
AGENT_STALL_TIMEOUT_MS=60000
OPENAI_BASE_URL=https://open.bigmodel.cn/api/paas/v4
BOT_MODEL=glm-4.7
AGENT_BOT_MODEL=glm-4.7
AGENT_COMPUTER_URL=http://localhost:4100
ENVEOF
  missing=""
  for k in OPENAI_API_KEY INTELLIGENCE_API_KEY CPK_INTELLIGENCE_API_KEY CPK_TELEMETRY_ID; do
    v="${!k:-}"
    if [ -n "$v" ]; then printf '%s=%s\n' "$k" "$v" >> .env; else missing="$missing $k"; fi
  done
  sed -i "s|^KEY_ENCRYPTION_KEY=.*|KEY_ENCRYPTION_KEY=$(openssl rand -base64 32)|" .env
  chmod 600 .env
  if [ -n "$missing" ]; then
    log "MISSING SECRETS:$missing"
    status "secrets: MISSING$missing"
  else
    log "all secrets present"
    status "secrets: all present"
  fi
fi

# ---------------------------------------------------------------------------
# 3. public URLs for this codespace
# ---------------------------------------------------------------------------
if [ -n "${CODESPACE_NAME:-}" ]; then
  sed -i -e "s|NAME_ME|$CODESPACE_NAME|g" -e "s|CHANGE_ME|$CODESPACE_NAME|g" .env
  log "public URLs point at $CODESPACE_NAME"
else
  log "CODESPACE_NAME is unset"
  status "codespace name: UNKNOWN"
fi

# ---------------------------------------------------------------------------
# 4. tenant model + vite allowed hosts
# ---------------------------------------------------------------------------
sed -i 's/default_model:.*/default_model: glm-4.7/' openbot/examples/openduet/model.yaml 2>/dev/null || true
if ! grep -q 'allowedHosts' openbot/app/vite.config.ts 2>/dev/null; then
  sed -i 's/strictPort: true,/strictPort: true, allowedHosts: true,/' openbot/app/vite.config.ts
  log "patched vite allowedHosts"
fi

# ---------------------------------------------------------------------------
# 5. bun
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  if [ -x "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  else
    log "installing bun"
    curl -fsSL https://bun.sh/install 2>>"$LOG" | bash >>"$LOG" 2>&1
    export PATH="$HOME/.bun/bin:$PATH"
  fi
fi
command -v bun >/dev/null 2>&1 && log "bun: $(bun --version 2>/dev/null)" || { log "bun MISSING"; status "bun: MISSING"; }

# ---------------------------------------------------------------------------
# 6. make 3010/3001 public, retrying in the background (ports only exist once
#    something listens, and GitHub forgets visibility after a restart)
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  (
    for i in $(seq 1 120); do
      for p in 3010 3001; do
        curl -s -X PATCH \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          -o /dev/null -w "%{http_code} $p\n" \
          "https://api.github.com/user/codespaces/$CODESPACE_NAME/ports/$p" \
          -d '{"visibility":"public"}' >> "$LOG" 2>&1
      done
      sleep 10
    done
  ) &
  log "port-visibility loop started"
else
  log "no GITHUB_TOKEN; skipping port visibility loop"
  status "port visibility: skipped"
fi

# ---------------------------------------------------------------------------
# 7. is the stack already up?
# ---------------------------------------------------------------------------
if curl -fsS --max-time 5 http://localhost:3001/api/capabilities >/dev/null 2>&1; then
  log "server already answering; not restarting the stack"
  status "stack: already running"
else
  # Anything still building from a previous attempt would hold the compose lock.
  log "starting the stack (log: $STACK)"
  status "stack: starting (watch _stack.log)"
  : > "$STACK"
  nohup bash scripts/start.sh >> "$STACK" 2>&1 &
  log "stack launched, pid $!"
fi

# ---------------------------------------------------------------------------
# 8. final snapshot
# ---------------------------------------------------------------------------
{
  echo "--- docker containers ---"
  docker compose -f openbot/docker-compose.yml ps 2>&1 | tail -n 15
  echo "--- listeners on 3001/3010 ---"
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | grep -E ':(3001|3010)' || echo "none"
  echo "--- last 20 lines of _stack.log ---"
  tail -n 20 "$STACK" 2>/dev/null
} >> "$LOG" 2>&1
log "setup done"
status "setup done $(date)"
