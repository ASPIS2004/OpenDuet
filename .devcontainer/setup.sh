#!/usr/bin/env bash
# OpenDuet Codespace bootstrap — production mode + Cloudflare quick tunnel. (v6)
#
# v6 changes:
#   - secrets clone is strictly non-interactive (GIT_TERMINAL_PROMPT=0,
#     GIT_ASKPASS disabled, timeout 90s) — v5 hung forever waiting for
#     credentials in the task terminal
#   - git fetch force-updates the remote-tracking ref so the self-update
#     rebase actually sees new commits
set -uo pipefail

# v10: re-exec from a private copy — the in-script rebase replaces this file,
# which would shift bash's read offset mid-execution and corrupt the run.
if [ -z "${OPENBOT_SETUP_REEXEC:-}" ]; then
  export OPENBOT_SETUP_REEXEC=1
  cp "$0" /tmp/.setup_running.sh 2>/dev/null || true
  exec bash /tmp/.setup_running.sh "$@"
fi

cd /workspaces/OpenDuet 2>/dev/null || cd "$(pwd)"
W="$(pwd -P)"
LOG="$W/_setup.log"
STACK="$W/_stack.log"
STATUS="$W/_STATUS.txt"
log(){ echo "[$(date +%T)] $*" >> "$LOG"; }

: > "$STATUS"

# Always take the newest bootstrap from GitHub before doing anything. Local
# status-only commits are expendable: rebase them on, or drop them and reset.
git fetch origin '+refs/heads/main:refs/remotes/origin/main' --force >> "$LOG" 2>&1 \
  || log "git fetch failed (continuing offline)"
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
# 4. .env — base config
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
  chmod 600 .env
fi

# 4a. merge secrets from environment (Codespace user secrets) — every run
for k in OPENAI_API_KEY INTELLIGENCE_API_KEY CPK_INTELLIGENCE_API_KEY CPK_TELEMETRY_ID; do
  v="${!k:-}"
  [ -z "$v" ] && continue
  if grep -qE "^$k=..+" .env; then
    continue
  fi
  if grep -qE "^$k=" .env; then
    sed -i "s|^$k=.*|$k=$v|" .env
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
  log "secret $k merged from environment"
done

# 4b. secrets from private repo openduet-env (file: secrets.env), with gh fallback
# Non-interactive: never prompt for credentials, never hang the task terminal.
if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true \
   timeout 90 git clone --depth 1 -q https://github.com/ASPIS2004/openduet-env.git /tmp/envrepo 2>/tmp/clone_err; then
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
  CE="$(tail -n 2 /tmp/clone_err 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
  log "clone openduet-env FAILED: $CE"
  echo "secrets: private repo clone FAILED: $CE" >> "$STATUS"
  rm -f /tmp/clone_err
  if command -v gh >/dev/null 2>&1 \
     && gh api repos/ASPIS2004/openduet-env/contents/secrets.env --jq '.content' 2>>"$LOG" \
     | base64 -d > /tmp/secrets.env 2>>"$LOG" && [ -s /tmp/secrets.env ]; then
    while IFS='=' read -r k v; do
      [ -z "$k" ] && continue
      case "$k" in \#*) continue ;; esac
      if grep -qE "^$k=" .env; then
        sed -i "s|^$k=.*|$k=$v|" .env
      else
        printf '%s=%s\n' "$k" "$v" >> .env
      fi
    done < /tmp/secrets.env
    log "secrets merged via gh api"
    echo "secrets: merged via gh api" >> "$STATUS"
  fi
  rm -f /tmp/secrets.env
fi

# 4c. final secrets summary
sm=""
for k in OPENAI_API_KEY INTELLIGENCE_API_KEY CPK_INTELLIGENCE_API_KEY CPK_TELEMETRY_ID; do
  grep -qE "^$k=..+" .env || sm="$sm $k"
done
if [ -z "$sm" ]; then
  echo "secrets: ALL SET" >> "$STATUS"
else
  echo "secrets: STILL MISSING$sm" >> "$STATUS"
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
  echo "cloudflared: $(/usr/local/bin/cloudflared --version 2>&1 | head -1 | cut -c1-60)" >> "$STATUS"
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
else
  echo "cloudflared: DOWNLOAD FAILED" >> "$STATUS"
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
  tail -n 15 "$W/_tunnel.log" >> "$LOG" 2>&1
  echo "--- _tunnel.log tail ---" >> "$STATUS"
  tail -n 15 "$W/_tunnel.log" >> "$STATUS" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 7. make the codespace ports public too (best-effort fallback)
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  (
    for i in $(seq 1 60); do
      for p in 3001 3010; do
        curl -s -X PATCH \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          -o /dev/null \
          "https://api.github.com/user/codespaces/$CODESPACE_NAME/ports/$p" \
          -d '{"visibility":"public"}' 2>>"$LOG"
      done
      sleep 15
    done
  ) &
fi

# ---------------------------------------------------------------------------
# 8. start the stack (docker compose + migrate + server, all idempotent)
# ---------------------------------------------------------------------------
# One-time DB volume reset: fixes "Migrations did not apply" from a stale
# postgres volume created by earlier failed runs. Guarded by marker file.
if [ ! -f .db_reset_done ]; then
  ( cd "$W" && docker compose down -v >> "$LOG" 2>&1 || true )
  touch .db_reset_done
  echo "db: volume reset (one-time)" >> "$STATUS"
fi
if curl -fsS --max-time 5 http://localhost:3001/api/capabilities >/dev/null 2>&1; then
  echo "stack: already running" >> "$STATUS"
else
  echo "stack: starting (docker build takes a while; watch _stack.log)" >> "$STATUS"
  : > "$STACK"
  # v11: setsid escapes the lifecycle runner's process group — plain nohup'd
  # children were being SIGKILLed when postStartCommand exited, killing the
  # server before it could bind 3001. A new session survives.
  setsid nohup bash scripts/start.sh >> "$STACK" 2>&1 < /dev/null &
fi

# ---------------------------------------------------------------------------
# 9. report status, including a short stack tail, and push it to the fork
# ---------------------------------------------------------------------------
sleep 20
{
  echo "server: $(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:3001/api/capabilities 2>/dev/null || echo down)"
  echo "tunnel_url: ${TURL:-none}"
  echo "---"
  tail -n 15 "$STACK" 2>/dev/null
} >> "$STATUS"

git add -f _STATUS.txt >> "$LOG" 2>&1
git -c user.email=setup@codespace -c user.name=setup \
  commit -m "status update" >> "$LOG" 2>&1
git push >> "$LOG" 2>&1 && log "status pushed" || log "status push failed"
echo "setup done $(date '+%F %T')" >> "$STATUS"

# v9: detached diagnostics — nohup so it survives lifecycle-command exit
cat > "$W/_diag9.sh" <<'DIAGEOF'
#!/usr/bin/env bash
cd /workspaces/OpenDuet
sleep 240
{
  echo "=== v9 diag $(date '+%T') ==="
  echo "listeners:"; ss -tlnp 2>/dev/null | grep -E ':(3001|3010|3000)' || echo "none listening"
  echo "procs:"; pgrep -af "bun|node" 2>/dev/null | head -10 || echo "no bun/node procs"
  echo "docker:"; docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | head -8
  echo "--- _stack.log tail 100 ---"
  tail -n 100 _stack.log 2>/dev/null
  echo "--- _setup.log tail 30 ---"
  tail -n 30 _setup.log 2>/dev/null
  echo "--- server log tail ---"
  tail -n 60 openbot/.logs/server.log 2>/dev/null
  echo "--- migrate.log tail 40 ---"
  tail -n 40 openbot/.logs/migrate.log 2>/dev/null
} >> _STATUS.txt
git add -f _STATUS.txt
git -c user.email=setup@codespace -c user.name=setup commit -m "status update"
git push
echo "diag9 done $(date '+%F %T')" >> /workspaces/OpenDuet/_setup.log
DIAGEOF
chmod +x "$W/_diag9.sh"
setsid nohup "$W/_diag9.sh" >/dev/null 2>&1 < /dev/null &
