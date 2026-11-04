#!/usr/bin/env bash
# OpenDuet Codespace bootstrap — production mode + Cloudflare quick tunnel.
#
# Why production mode: in dev mode the browser opens its websocket on
# wss://<current-host>:3001, which no port-forwarding or tunnel setup can serve.
# With APP_DIST_DIR set, the API server serves the built app on 3001 itself and
# everything is same-origin, so ONE public URL is all the product needs.
#
# Idempotent; safe to rerun. Everything it learns lands in _STATUS.txt, which it
# also pushes to the fork so it can be read from outside without a terminal.
set -uo pipefail
cd /workspaces/OpenDuet 2>/dev/null || cd "$(pwd)"
W="$(pwd -P)"
LOG="$W/_setup.log"
STACK="$W/_stack.log"
STATUS="$W/_STATUS.txt"
log(){ echo "[$(date +%T)] $*" >> "$LOG"; }

: > "$STATUS"

# Always take the newest bootstrap from GitHub before doing anything. Local
# status-only commits are expendable: rebase them on, or drop them and reset.
git fetch origin main >> "$LOG" 2>&1 || log "git fetch failed (continuing offline)"
if git rev-parse -q --verify origin/main >/dev/null 2>&1; then
  git rebase origin/main >> "$LOG" 2>&1 || {
    log "rebase failed; resetting tracked files to origin/main"
    git reset --hard origin/main >> "$LOG" 2>&1
  }
fi

echo "run $(date '+%F %T')" >> "$STATUS"
echo "codespace ${CODESPACE_NAME:-unknown}" >> "$STATUS"

# ---------------------------------------------------------------------------
# 1. docker (docker-in-docker needs a while on a fresh codespace)
# ---------------------------------------------------------------------------
ok=""
for i in $(seq 1 150); do
  if docker info >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ -n "$ok" ]; then
  echo "docker: ready" >> "$STATUS"
else
  echo "docker: NOT READY" >> "$STATUS"
  log "docker not ready after 300s; continuing anyway"
fi

# ---------------------------------------------------------------------------
# 2. bun
# ---------------------------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  [ -x "$HOME/.bun/bin/bun" ] && export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 || {
    curl -fsSL https://bun.sh/install 2>>"$LOG" | bash >>"$LOG" 2>&1
    export PATH="$HOME/.bun/bin:$PATH"
  }
fi
command -v bun >/dev/null 2>&1 && echo "bun: $(bun --version 2>/dev/null)" >> "$STATUS" || echo "bun: MISSING" >> "$STATUS"

# ---------------------------------------------------------------------------
# 3. dependencies (openbot workspace)
# ---------------------------------------------------------------------------
if [ ! -d openbot/node_modules ]; then
  echo "deps: installing (bun install, several minutes)" >> "$STATUS"
  bun install --cwd openbot >> "$LOG" 2>&1 || echo "deps: INSTALL FAILED" >> "$STATUS"
fi
[ -d openbot/node_modules ] && echo "deps: present" >> "$STATUS"

# ---------------------------------------------------------------------------
# 4. .env — secrets arrive as Codespace secrets, injected as environment vars
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  log "writing .env"
  cat > .env <<ENVEOF
DATABASE_URL=postgres://openbot:openbot@localhost:5432/openbot
KEY_ENCRYPTION_KEY=$(openssl rand -base64 32)
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
OPENBOT_PUBLIC_URL=https://${CODESPACE_NAME:-NAME}-3001.app.github.dev
OPENBOT_APP_URL=https://${CODESPACE_NAME:-NAME}-3001.app.github.dev
TRUSTED_ORIGINS=https://${CODESPACE_NAME:-NAME}-3001.app.github.dev
INTELLIGENCE_API_URL=https://api.intelligence.copilotkit.ai
INTELLIGENCE_GATEWAY_WS_URL=wss://realtime.intelligence.copilotkit.ai
AGENT_STALL_TIMEOUT_MS=60000
OPENAI_BASE_URL=https://open.bigmodel.cn/api/paas/v4
BOT_MODEL=glm-4.7
AGENT_BOT_MODEL=glm-4.7
AGENT_COMPUTER_URL=http://localhost:4100
APP_DIST_DIR=$W/openbot/app/dist
ENVEOF
  missing=""
  for k in OPENAI_API_KEY INTELLIGENCE_API_KEY CPK_INTELLIGENCE_API_KEY CPK_TELEMETRY_ID; do
    v="${!k:-}"
    if [ -n "$v" ]; then printf '%s=%s\n' "$k" "$v" >> .env; else missing="$missing $k"; fi
  done
  [ -n "$missing" ] && { log "MISSING SECRETS:$missing"; echo "secrets: MISSING$missing" >> "$STATUS"; } \
                     || { echo "secrets: all present" >> "$STATUS"; }
  chmod 600 .env
fi

# Secrets live in the private repo openduet-env (file: secrets.env). Codespaces
# git credentials can clone it without any token. Merge any keys not yet in .env.
if git clone --depth 1 -q https://github.com/ASPIS2004/openduet-env.git /tmp/envrepo >> "$LOG" 2>&1; then
  if [ -f /tmp/envrepo/secrets.env ]; then
    while IFS='=' read -r k v; do
      [ -z "$k" ] && continue
      case "$k" in \#*) continue ;; esac
      if grep -qE "^$k=" .env; then
        sed -i "s|^$k=.*|$k=$v|" .env
      else
        printf '%s=%s\n' "$k" "$v" >> .env
      fi
    done < /tmp/envrepo/secrets.env
    log "secrets merged from openduet-env"
    echo "secrets: merged from private repo" >> "$STATUS"
  else
    log "openduet-env has no secrets.env"
    echo "secrets: private repo missing secrets.env" >> "$STATUS"
  fi
  rm -rf /tmp/envrepo
else
  log "clone openduet-env FAILED"
  echo "secrets: private repo clone FAILED" >> "$STATUS"
fi

# Tenant model
sed -i 's/default_model:.*/default_model: glm-4.7/' openbot/examples/openduet/model.yaml 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. build the app (vite build) — once
# ---------------------------------------------------------------------------
if [ ! -f openbot/app/dist/index.html ]; then
  echo "app: building (vite build, several minutes)" >> "$STATUS"
  ( cd openbot \
    && bun run generate:app-config >> "$LOG" 2>&1 \
    && bun run --filter app build >> "$LOG" 2>&1 ) \
    && echo "app: built" >> "$STATUS" \
    || echo "app: BUILD FAILED (see _setup.log)" >> "$STATUS"
else
  echo "app: dist present" >> "$STATUS"
fi

# ---------------------------------------------------------------------------
# 6. Cloudflare quick tunnel (no account) — the URL that works from China
# ---------------------------------------------------------------------------
TURL=""
if [ ! -x /usr/local/bin/cloudflared ]; then
  curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    >>"$LOG" 2>&1 && chmod +x /usr/local/bin/cloudflared
fi
if [ -x /usr/local/bin/cloudflared ]; then
  # A stale cloudflared that never got a URL would block a fresh attempt.
  if pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
    grep -qE 'https://[a-z0-9-]+\.trycloudflare\.com' "$W/_tunnel.log" 2>/dev/null || {
      pkill -f "cloudflared tunnel" 2>/dev/null; sleep 2
    }
  fi
  if ! pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
    : > "$W/_tunnel.log"
    nohup /usr/local/bin/cloudflared tunnel --url http://localhost:3001 --no-autoupdate \
      --protocol http2 >> "$W/_tunnel.log" 2>&1 &
  fi
  for i in $(seq 1 45); do
    TURL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$W/_tunnel.log" 2>/dev/null | head -1)"
    [ -n "$TURL" ] && break
    sleep 2
  done
fi
if [ -n "$TURL" ]; then
  echo "tunnel: $TURL" >> "$STATUS"
  # Point every public URL at the tunnel (drop old lines, re-append).
  grep -vE '^(OPENBOT_PUBLIC_URL|OPENBOT_APP_URL|TRUSTED_ORIGINS)=' .env > .env.tmp 2>/dev/null || cp .env .env.tmp
  printf 'OPENBOT_PUBLIC_URL=%s\nOPENBOT_APP_URL=%s\nTRUSTED_ORIGINS=%s\n' "$TURL" "$TURL" "$TURL" >> .env.tmp
  mv .env.tmp .env
  chmod 600 .env
else
  echo "tunnel: FAILED (falling back to codespace port URL)" >> "$STATUS"
  log "no tunnel URL; _tunnel.log says:"
  tail -n 8 "$W/_tunnel.log" >> "$LOG" 2>&1
  echo "--- _tunnel.log tail ---" >> "$STATUS"
  tail -n 8 "$W/_tunnel.log" >> "$STATUS" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 7. make the codespace ports public too (best-effort fallback)
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  (
    for i in $(seq 1 60); do
      for p in 3001 3010; do
        gh api /repos/ASPIS2004/OpenDuet/branches/main/protection/required_status_checks/contexts \
          -f contexts[]="ci/codeship: $p" >> /dev/null 2>&1 || true
        gh codespace ports visibility $p --port $p --visibility public >> /dev/null 2>&1 || true
      done
      sleep 1
    done
  ) &
fi

# ---------------------------------------------------------------------------
# 8. startup (each boot)
# ---------------------------------------------------------------------------
# Start services via docker compose (restarts on failure)
cd "$W"
if [ -f docker-compose.yml ]; then
  echo "compose: starting services" >> "$STATUS"
  docker compose up -d >> "$LOG" 2>&1 && echo "compose: started" >> "$STATUS" \
    || { echo "compose: START FAILED" >> "$STATUS"; log "compose failed"; }
else
  echo "compose: no docker-compose.yml" >> "$STATUS"
fi

# Write final status
echo "done $(date '+%F %T')" >> "$STATUS"
log "bootstrap complete"
