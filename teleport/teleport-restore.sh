#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  teleport-restore.sh — Rebuild OpenClaw stack from backup + git         ║
# ║  Project Teleport (Mel Miles mode)                                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# Usage:
#   bash teleport-restore.sh --backup /path/to/openclaw-backup.tar.gz.gpg \
#                             --key-file /path/to/backup.key \
#                             --github-token <token> \
#                             --user alex \
#                             [--workspace-repo git@github.com:user/repo.git] \
#                             [--tools-bind 127.0.0.1:8443] \
#                             [--tools-password <password>]
#
# Notes:
#   - --user is required and must NOT be root
#   - Script must run as root (to create user + install system deps)
#   - If user doesn't exist, it's created with a random temp password
#   - Temp password saved to /root/openclaw-user-password.txt (root-readable)
#   - Backup key: read from file (--key-file). Mirror to 1Password for emergency recovery only.
#
# Execution model:
#   ROOT ZONE  (phases 1-2 + user setup): runs as root
#   USER ZONE  (phases 3-11):             re-exec'd as TARGET_USER via su
#
# What this script does:
#    1. Installs system dependencies (Docker, Node.js, tools)
#    2. Starts Qdrant + Neo4j containers
#    3. Installs OpenClaw globally
#    4. Decrypts and extracts backup archive
#    5. Restores workspace from git (mel-memory repo)
#    6. Restores Qdrant vectors from snapshot
#    7. Restores Neo4j graph from export
#    8. Restores openclaw.json + hooks
#    9. Sets up systemd service + cron jobs
#   9.5. Installs + configures Tools Config Server
#   10. Verifies everything is alive
#   11. Starts services
#
# Prerequisites on new machine: bash, curl, internet access
# Supervised install: run via agent exec tool — agent monitors [PHASE] markers

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

phase() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}[PHASE] $1${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $1" >&2; exit 1; }
check() { echo -e "${CYAN}[CHECK]${NC} $1"; }

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# USER ZONE — triggered by --user-phase, runs as TARGET_USER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ "${1:-}" == "--user-phase" ]]; then

  # Source env passed from root zone
  ENV_FILE="${2:-}"
  [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ] && { echo "[FAIL] env file not found: $ENV_FILE" >&2; exit 1; }
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  # Cleanup trap — remove env file + backup tmp on exit
  trap "rm -f '$ENV_FILE' '$BACKUP_TMP'" EXIT

  # Derived paths (safe to compute here since TARGET_HOME is now set)
  OPENCLAW_DIR="${TARGET_HOME}/.openclaw"
  WORKSPACE_DIR="${OPENCLAW_DIR}/workspace"
  NPM_GLOBAL="${TARGET_HOME}/.npm-global"
  SYSTEMD_USER_DIR="${TARGET_HOME}/.config/systemd/user"

  # ── Phase 3/11: Install OpenClaw ───────────────────────────────────────────
  phase "3/11 — OpenClaw global install"

  mkdir -p "$NPM_GLOBAL"
  npm config set prefix "$NPM_GLOBAL"

  # Add npm-global/bin to PATH in .bashrc and .profile
  for rcfile in "${TARGET_HOME}/.bashrc" "${TARGET_HOME}/.profile"; do
    if ! grep -q "npm-global/bin" "$rcfile" 2>/dev/null; then
      echo "" >> "$rcfile"
      echo "# OpenClaw / npm global binaries" >> "$rcfile"
      echo "export PATH=\"\$HOME/.npm-global/bin:\$PATH\"" >> "$rcfile"
    fi
  done

  if ! command -v openclaw &>/dev/null && [ ! -f "${NPM_GLOBAL}/bin/openclaw" ]; then
    info "Installing OpenClaw..."
    PATH="${NPM_GLOBAL}/bin:$PATH" npm install -g openclaw 2>&1 | tail -5
    ok "OpenClaw installed"
  else
    ok "OpenClaw already installed: $(PATH="${NPM_GLOBAL}/bin:$PATH" openclaw --version 2>/dev/null || echo "unknown")"
  fi

  ok "OpenClaw ready (extensions will be restored from backup in Phase 8)"

  # ── Phase 4/11: Decrypt and extract backup ─────────────────────────────────
  phase "4/11 — Decrypt backup archive"

  WORK_DIR="/tmp/openclaw-restore-$$"
  mkdir -p "$WORK_DIR"
  trap "rm -rf '$WORK_DIR'; rm -f '$ENV_FILE' '$BACKUP_TMP'" EXIT

  info "Decrypting backup archive..."
  KEYFILE=$(mktemp)
  chmod 600 "$KEYFILE"
  printf '%s' "$BACKUP_KEY" > "$KEYFILE"
  gpg --batch --yes --passphrase-file "$KEYFILE" --decrypt \
    --output "${WORK_DIR}/backup.tar.gz" \
    "$BACKUP_TMP" 2>/dev/null
  rm -f "$KEYFILE"
  [ -f "${WORK_DIR}/backup.tar.gz" ] || fail "Decryption failed — check backup key"

  info "Extracting archive..."
  tar xzf "${WORK_DIR}/backup.tar.gz" -C "$WORK_DIR"

  EXTRACT_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "openclaw-backup-*" | head -1)
  [ -z "$EXTRACT_DIR" ] && fail "Could not find extracted backup directory"
  ok "Archive extracted: $(basename "$EXTRACT_DIR")"
  ls -la "$EXTRACT_DIR/"

  # ── Phase 5/11: Restore workspace from git ─────────────────────────────────
  phase "5/11 — Workspace restore (git)"

  mkdir -p "${OPENCLAW_DIR}"

  if [ -d "${WORKSPACE_DIR}/.git" ]; then
    info "Workspace already cloned, pulling latest..."
    cd "${WORKSPACE_DIR}" && git pull origin master 2>&1 || true
  else
    if [ -d "${WORKSPACE_DIR}" ]; then
      warn "Removing incomplete workspace dir..."
      rm -rf "${WORKSPACE_DIR}"
    fi
    info "Cloning workspace repository..."
    CLONE_URL="$WORKSPACE_REPO"
    if [ -n "$GITHUB_TOKEN" ] && [[ "$CLONE_URL" == https://github.com/* ]]; then
      CLONE_URL="${CLONE_URL/https:\/\//https://${GITHUB_TOKEN}@}"
    fi
    git clone "$CLONE_URL" "$WORKSPACE_DIR" 2>&1 || fail "git clone failed"
  fi
  ok "Workspace ready at ${WORKSPACE_DIR}"

  # ── Phase 6/11: Restore Qdrant vectors ─────────────────────────────────────
  phase "6/11 — Restore Qdrant vectors"

  SNAPSHOT_FILE=$(find "$EXTRACT_DIR" -name "*.snapshot" | head -1)

  if [ -n "$SNAPSHOT_FILE" ]; then
    SNAP_NAME=$(basename "$SNAPSHOT_FILE")
    info "Uploading snapshot: $SNAP_NAME"
    curl -sf -X POST \
      "http://localhost:${QDRANT_PORT}/collections/openclaw_memories/snapshots/upload?priority=snapshot" \
      -H "Content-Type: multipart/form-data" \
      -F "snapshot=@${SNAPSHOT_FILE}" > /dev/null \
      && ok "Qdrant snapshot restored" \
      || warn "Qdrant snapshot restore failed — will start with empty collection"
  else
    warn "No Qdrant snapshot found in backup — starting with empty collection"
    curl -sf -X PUT "http://localhost:${QDRANT_PORT}/collections/openclaw_memories" \
      -H "Content-Type: application/json" \
      -d '{"vectors": {"size": 1536, "distance": "Cosine"}}' > /dev/null || true
  fi

  COLLECTION_INFO=$(curl -sf "http://localhost:${QDRANT_PORT}/collections/openclaw_memories" 2>/dev/null)
  if echo "$COLLECTION_INFO" | jq -e '.result.status' > /dev/null 2>&1; then
    VECTORS=$(echo "$COLLECTION_INFO" | jq -r '.result.vectors_count // 0')
    ok "Qdrant collection ready (${VECTORS} vectors)"
  else
    warn "Could not verify Qdrant collection"
  fi

  # ── Phase 7/11: Restore Neo4j graph ────────────────────────────────────────
  phase "7/11 — Restore Neo4j graph"

  GRAPH_FILE=$(find "$EXTRACT_DIR" -name "neo4j-graph-*.json" | head -1)
  NODES_FILE=$(find "$EXTRACT_DIR" -name "neo4j-nodes-*.json" | head -1)

  if [ -n "$GRAPH_FILE" ]; then
    info "Restoring Neo4j relationships..."
    python3 - <<PYEOF
import json, urllib.request, urllib.error, base64, sys

graph_file = "${GRAPH_FILE}"
nodes_file = "${NODES_FILE}" if "${NODES_FILE}" else None
neo4j_url = "http://localhost:${NEO4J_HTTP_PORT}/db/neo4j/query/v2"
auth = base64.b64encode(b"${NEO4J_AUTH}").decode()
headers = {"Content-Type": "application/json", "Authorization": f"Basic {auth}"}

def run_cypher(stmt, params=None):
    body = json.dumps({"statement": stmt, "parameters": params or {}}).encode()
    req = urllib.request.Request(neo4j_url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"  [warn] Cypher error: {e}")
        return None

with open(graph_file) as f:
    data = json.load(f)

rows = data.get("data", {}).get("values", []) or data.get("results", [{}])[0].get("data", []) if isinstance(data, dict) else []

count = 0
for row in rows:
    vals = row.get("row", row) if isinstance(row, dict) else row
    if len(vals) >= 5:
        src, rel, tgt = str(vals[0] or ""), str(vals[3] or ""), str(vals[4] or "")
        uid = str(vals[2] or "")
        if src and rel and tgt:
            stmt = f"""
MERGE (a:Entity {{name: "{src}", user_id: "{uid}"}})
MERGE (b:Entity {{name: "{tgt}"}})
MERGE (a)-[:{rel}]->(b)
"""
            run_cypher(stmt)
            count += 1

print(f"  Restored {count} relationships")
PYEOF
    ok "Neo4j graph restored"
  else
    warn "No Neo4j graph export found — starting with empty graph"
  fi

  # ── Phase 8/11: Restore configs and hooks ──────────────────────────────────
  phase "8/11 — Restore configs + hooks"

  # openclaw.json
  if [ -f "${EXTRACT_DIR}/openclaw.json" ]; then
    cp "${EXTRACT_DIR}/openclaw.json" "${OPENCLAW_DIR}/openclaw.json"
    chmod 600 "${OPENCLAW_DIR}/openclaw.json"
    ok "openclaw.json restored"
    if [ -n "$TELEGRAM_TOKEN_ARG" ]; then
      jq --arg tok "$TELEGRAM_TOKEN_ARG" '.channels.telegram.botToken = $tok' \
        "${OPENCLAW_DIR}/openclaw.json" > /tmp/openclaw.json.tmp \
        && mv /tmp/openclaw.json.tmp "${OPENCLAW_DIR}/openclaw.json" \
        && chmod 600 "${OPENCLAW_DIR}/openclaw.json"
      ok "Telegram bot token injected from --telegram-token"
    fi
  else
    fail "openclaw.json not found in backup — cannot continue without config"
  fi

  # auth-profiles.json — API keys, lives at agents/main/agent/
  if [ -f "${EXTRACT_DIR}/auth-profiles.json" ]; then
    mkdir -p "${OPENCLAW_DIR}/agents/main/agent"
    cp "${EXTRACT_DIR}/auth-profiles.json" "${OPENCLAW_DIR}/agents/main/agent/auth-profiles.json"
    chmod 600 "${OPENCLAW_DIR}/agents/main/agent/auth-profiles.json"
    ok "auth-profiles.json restored"
  else
    warn "auth-profiles.json not in backup — models will not work without API keys"
  fi

  # hooks/
  if [ -d "${EXTRACT_DIR}/hooks" ]; then
    mkdir -p "${OPENCLAW_DIR}/hooks"
    cp -r "${EXTRACT_DIR}/hooks/." "${OPENCLAW_DIR}/hooks/"
    chmod +x "${OPENCLAW_DIR}/hooks/"*.sh 2>/dev/null || true
    ok "Hooks restored"
  fi

  # Extensions
  if [ -f "${EXTRACT_DIR}/extensions.tar.gz" ]; then
    info "Restoring local extensions..."
    mkdir -p "${OPENCLAW_DIR}/extensions"
    tar xzf "${EXTRACT_DIR}/extensions.tar.gz" -C "${OPENCLAW_DIR}" 2>/dev/null
    for ext_dir in "${OPENCLAW_DIR}/extensions"/*/; do
      if [ -f "${ext_dir}/package.json" ]; then
        ext_name=$(basename "$ext_dir")
        if [ -f "${ext_dir}/package-lock.json" ]; then
          cd "${ext_dir}" && PATH="${NPM_GLOBAL}/bin:/usr/local/bin:/usr/bin:/bin" npm ci --quiet 2>&1 | tail -2 \
            && info "  ✓ ${ext_name} deps installed (npm ci)" \
            || warn "  ✗ ${ext_name} npm ci failed (non-fatal)"
        else
          cd "${ext_dir}" && PATH="${NPM_GLOBAL}/bin:/usr/local/bin:/usr/bin:/bin" npm install --quiet 2>&1 | tail -2 \
            && info "  ✓ ${ext_name} deps installed (npm install)" \
            || warn "  ✗ ${ext_name} npm install failed (non-fatal)"
        fi
      fi
    done
    ok "Extensions restored"
  else
    warn "No extensions.tar.gz in backup — gateway will fail to start until plugins are installed manually"
  fi

  # SQLite history
  if [ -f "${EXTRACT_DIR}/history.db" ]; then
    mkdir -p "${OPENCLAW_DIR}/mem0-oss"
    cp "${EXTRACT_DIR}/history.db" "${OPENCLAW_DIR}/mem0-oss/history.db"
    ok "SQLite history restored"
  fi

  # Root-level scripts
  if [ -d "${EXTRACT_DIR}/scripts" ]; then
    for script in backup-mem0.sh backup.sh health-watchdog.sh memory-daily-check.sh preflight.sh scheduled-checkin.sh; do
      if [ -f "${EXTRACT_DIR}/scripts/${script}" ]; then
        cp "${EXTRACT_DIR}/scripts/${script}" "${OPENCLAW_DIR}/${script}"
        chmod +x "${OPENCLAW_DIR}/${script}"
      fi
    done
    ok "Operational scripts restored from backup"
  else
    warn "No scripts/ dir in backup — falling back to workspace copies"
    for script in backup-mem0.sh backup.sh scheduled-checkin.sh health-watchdog.sh memory-daily-check.sh preflight.sh; do
      if [ -f "${WORKSPACE_DIR}/${script}" ]; then
        cp "${WORKSPACE_DIR}/${script}" "${OPENCLAW_DIR}/${script}"
        chmod +x "${OPENCLAW_DIR}/${script}"
      fi
    done
    ok "Operational scripts in place (from workspace)"
  fi

  # ── Phase 9/11: Systemd + cron ─────────────────────────────────────────────
  phase "9/11 — Systemd service + cron"

  mkdir -p "$SYSTEMD_USER_DIR"

  TELEGRAM_TOKEN=$(jq -r '.channels.telegram.botToken // empty' "${OPENCLAW_DIR}/openclaw.json" 2>/dev/null || echo "")
  NODE_BIN=$(which node 2>/dev/null || echo "/usr/bin/node")
  OPENCLAW_MAIN="${NPM_GLOBAL}/lib/node_modules/openclaw/dist/index.js"
  TARGET_UID=$(id -u)

  cat > "${SYSTEMD_USER_DIR}/openclaw-gateway.service" << SERVICE
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${NODE_BIN} ${OPENCLAW_MAIN} gateway --port 18789
Restart=always
RestartSec=5
TimeoutStopSec=30
TimeoutStartSec=30
SuccessExitStatus=0 143
KillMode=control-group
Environment=HOME=${TARGET_HOME}
Environment=TMPDIR=/tmp
Environment=PATH=${NPM_GLOBAL}/bin:/usr/local/bin:/usr/bin:/bin
Environment=OPENCLAW_GATEWAY_PORT=18789
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway

[Install]
WantedBy=default.target
SERVICE

  XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user daemon-reload 2>/dev/null || true
  XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user enable openclaw-gateway 2>/dev/null || true

  ok "Systemd service configured"

  # Cron jobs
  CRON_CONTENT=$(crontab -l 2>/dev/null || echo "")

  add_cron() {
    local job="$1"
    local desc="$2"
    if echo "$CRON_CONTENT" | grep -qF "$job"; then
      info "Cron already set: $desc"
    else
      CRON_CONTENT="${CRON_CONTENT}"$'\n'"$job"
      info "Added cron: $desc"
    fi
  }

  add_cron "0 2 * * * ${OPENCLAW_DIR}/backup.sh"                                                                          "workspace git backup"
  add_cron "15 2 * * * ${OPENCLAW_DIR}/backup-mem0.sh"                                                                    "Mem0 encrypted backup"
  add_cron "*/15 * * * * ${OPENCLAW_DIR}/health-watchdog.sh"                                                              "system health watchdog (15min)"
  add_cron "0 */6 * * * ${OPENCLAW_DIR}/hooks/post-update.sh >> ${OPENCLAW_DIR}/logs/post-update.log 2>&1"                "post-update hooks (sqlite binding + graph patch)"
  add_cron "0 9,21 * * * ${WORKSPACE_DIR}/tools-server/cron-health-refresh.sh >> ${WORKSPACE_DIR}/logs/tools-health-refresh.log 2>&1" "tools server health refresh"
  add_cron "0 9 * * * ${OPENCLAW_DIR}/memory-daily-check.sh >> ${OPENCLAW_DIR}/logs/memory-daily-check.log 2>&1"          "memory daily check"
  add_cron "0 6 * * * qmd update workspace && qmd update memory >> ${OPENCLAW_DIR}/logs/qmd-update.log 2>&1"              "qmd index update"
  add_cron "0 6 * * * ${OPENCLAW_DIR}/preflight.sh >> ${OPENCLAW_DIR}/logs/preflight.log 2>&1"                            "preflight checks"
  add_cron "5 12 * * * ${WORKSPACE_DIR}/projects/groove-digest/send-digest.sh >> ${OPENCLAW_DIR}/logs/groove-digest.log 2>&1"  "Groove digest midday"
  add_cron "5 18 * * * ${WORKSPACE_DIR}/projects/groove-digest/send-digest.sh >> ${OPENCLAW_DIR}/logs/groove-digest.log 2>&1"  "Groove digest end of day"
  add_cron "0 9,11,13,15,17,19,21 * * * ${WORKSPACE_DIR}/projects/groove-digest/send-watchdog.sh >> ${OPENCLAW_DIR}/logs/groove-watchdog.log 2>&1" "Groove watchdog (stale tickets)"
  add_cron "30 1 * * * python3 ${OPENCLAW_DIR}/mark-flights-complete.py >> ${OPENCLAW_DIR}/logs/flights.log 2>&1"         "mark completed flight legs"
  add_cron "0 9 * * * cd ${WORKSPACE_DIR} && ${NPM_GLOBAL}/bin/openclaw security audit --deep >> ${OPENCLAW_DIR}/healthcheck.log 2>&1" "OpenClaw security audit"
  add_cron "0 10 * * 1 cd ${WORKSPACE_DIR} && ${NPM_GLOBAL}/bin/openclaw update status >> ${OPENCLAW_DIR}/healthcheck.log 2>&1" "OpenClaw update status (weekly)"

  echo "$CRON_CONTENT" | crontab -
  ok "Cron jobs installed"

  # Apply post-update hooks immediately
  info "Running post-update hooks..."
  bash "${OPENCLAW_DIR}/hooks/post-update.sh" 2>&1 || warn "post-update.sh had errors (non-fatal)"

  # Rebuild native Node modules
  info "Rebuilding native Node modules..."
  OCLAW_DIR="${NPM_GLOBAL}/lib/node_modules/openclaw"
  if [ -d "$OCLAW_DIR" ]; then
    cd "$OCLAW_DIR" && PATH="${NPM_GLOBAL}/bin:/usr/local/bin:/usr/bin:/bin" npm rebuild 2>&1 | tail -5
  else
    echo "openclaw module dir not found, skipping rebuild"
  fi || warn "npm rebuild had errors (non-fatal)"

  sleep 3

  # ── Phase 9.5/11: Tools Config Server ──────────────────────────────────────
  phase "9.5/11 — Tools Config Server"

  TOOLS_SERVER_DIR="${WORKSPACE_DIR}/tools-server"

  if [ -d "${TOOLS_SERVER_DIR}" ]; then
    info "Installing Tools Config Server dependencies..."
    cd "${TOOLS_SERVER_DIR}" && npm install --quiet 2>&1 | tail -3
    ok "Tools Config Server dependencies installed"

    # Restore tools.db (credentials, intent rules, behavior rules)
    if [ -f "${EXTRACT_DIR}/tools.db" ]; then
      mkdir -p "${TOOLS_SERVER_DIR}/data"
      cp "${EXTRACT_DIR}/tools.db" "${TOOLS_SERVER_DIR}/data/tools.db"
      chmod 600 "${TOOLS_SERVER_DIR}/data/tools.db"
      ok "tools.db restored — credentials and rules intact"
    elif [ -d "${EXTRACT_DIR}/tools-server-data" ]; then
      mkdir -p "${TOOLS_SERVER_DIR}/data"
      cp -r "${EXTRACT_DIR}/tools-server-data/." "${TOOLS_SERVER_DIR}/data/"
      ok "Tools Config Server data restored from backup (legacy format)"
    else
      warn "No tools.db in backup — server will start empty (re-enter credentials via dashboard at https://localhost:8443)"
    fi

    cat > "${SYSTEMD_USER_DIR}/tools-config-server.service" << SERVICE
[Unit]
Description=Streamliner Tools Config Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${TOOLS_SERVER_DIR}
ExecStart=/usr/bin/node ${TOOLS_SERVER_DIR}/server.js --bind ${TOOLS_BIND} --https --password ${TOOLS_PASSWORD}
Environment=TOOLS_AGENT_PORT=${TOOLS_AGENT_PORT}
Restart=always
RestartSec=10
Environment=HOME=${TARGET_HOME}
Environment=PATH=${NPM_GLOBAL}/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
SERVICE

    XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user daemon-reload 2>/dev/null || true
    XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user enable tools-config-server 2>/dev/null || true
    XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user start tools-config-server 2>/dev/null || true
    sleep 3
    ok "Tools Config Server service configured and started (bind: ${TOOLS_BIND})"
    ok "Agent endpoint: http://localhost:${TOOLS_AGENT_PORT} (no TLS, local only)"

    echo ""
    echo -e "  ${YELLOW}⚠️  Tools server password: ${TOOLS_PASSWORD}${NC}"
    echo -e "  ${YELLOW}   Save this — you'll need it to access the dashboard.${NC}"
    echo ""
  else
    warn "tools-server directory not found in workspace — skipping"
    warn "Install manually after restore: curl https://tools.streamliner.one | bash"
  fi

  # ── Phase 10/11: Verify ────────────────────────────────────────────────────
  phase "10/11 — Verification"

  PASS=0; FAIL=0

  verify() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
      ok "$desc"
      ((PASS++)) || true
    else
      warn "FAIL: $desc"
      ((FAIL++)) || true
    fi
  }

  verify "Docker running"                systemctl is-active --quiet docker
  verify "Qdrant healthy"               curl -sf "http://localhost:${QDRANT_PORT}/readyz"
  verify "Qdrant collection exists"     curl -sf "http://localhost:${QDRANT_PORT}/collections/openclaw_memories"
  verify "Neo4j accessible"             curl -sf "http://localhost:${NEO4J_HTTP_PORT}"
  verify "openclaw.json exists"         test -f "${OPENCLAW_DIR}/openclaw.json"
  verify "auth-profiles.json exists"    test -f "${OPENCLAW_DIR}/agents/main/agent/auth-profiles.json"
  verify "Workspace cloned"             test -d "${WORKSPACE_DIR}/.git"
  verify "Hooks executable"             test -x "${OPENCLAW_DIR}/hooks/post-update.sh"
  verify "OpenClaw binary exists"       test -f "${NPM_GLOBAL}/bin/openclaw"
  verify "Tools server dir exists"      test -d "${WORKSPACE_DIR}/tools-server"
  verify "Tools server deps"            test -d "${WORKSPACE_DIR}/tools-server/node_modules"
  verify "Tools server DB restored"     test -f "${WORKSPACE_DIR}/tools-server/data/tools.db"
  verify "Health watchdog exists"       test -f "${OPENCLAW_DIR}/health-watchdog.sh"
  verify "Backup script exists"         test -f "${OPENCLAW_DIR}/backup-mem0.sh"
  verify "Memory daily check exists"    test -f "${OPENCLAW_DIR}/memory-daily-check.sh"
  verify "Preflight script exists"      test -f "${OPENCLAW_DIR}/preflight.sh"
  verify "Groove digest exists"         test -f "${WORKSPACE_DIR}/projects/groove-digest/send-digest.sh"
  verify "Groove watchdog exists"       test -f "${WORKSPACE_DIR}/projects/groove-digest/send-watchdog.sh"
  verify "harden.sh available"          test -f "${WORKSPACE_DIR}/streamliner/teleport/harden.sh"

  # ── Phase 11/11: Start services ────────────────────────────────────────────
  phase "11/11 — Start services"

  # Ensure XDG runtime dir exists
  sudo mkdir -p "/run/user/${TARGET_UID}" 2>/dev/null || true
  sudo chown "${TARGET_USER}:${TARGET_USER}" "/run/user/${TARGET_UID}" 2>/dev/null || true
  sudo chmod 700 "/run/user/${TARGET_UID}" 2>/dev/null || true

  if [ -n "$TELEGRAM_TOKEN_ARG" ]; then
    info "Telegram bot token injected — starting gateway..."
    XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user start openclaw-gateway 2>/dev/null || true
    sleep 4
    if XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user is-active openclaw-gateway 2>/dev/null | grep -q "^active"; then
      ok "Gateway started — message your bot on Telegram to confirm"
    else
      warn "Gateway did not start — check: journalctl --user -u openclaw-gateway -n 20"
    fi
  else
    warn "Gateway NOT auto-started — no --telegram-token provided"
    info "  1. Create a new bot via @BotFather → /newbot"
    info "  2. Update ~/.openclaw/openclaw.json → channels.telegram.token"
    info "  3. Start gateway: XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user start openclaw-gateway"
  fi

  info "Starting Tools Config Server..."
  XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user start tools-config-server 2>/dev/null || true
  sleep 2
  if XDG_RUNTIME_DIR=/run/user/${TARGET_UID} systemctl --user is-active tools-config-server 2>/dev/null | grep -q "^active"; then
    ok "Tools Config Server started"
  else
    warn "Tools server did not start — check: journalctl --user -u tools-config-server -n 20"
  fi

  # ── Detect Tailscale + dashboard URL ─────────────────────────────────────
  TAILSCALE_HOSTNAME=""
  TAILSCALE_CERT_STATUS="not available"
  DASHBOARD_URL="http://localhost:8443 (SSH tunnel required)"
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    TAILSCALE_HOSTNAME=$(tailscale status --json 2>/dev/null | grep -o '"Self":{"ID":"[^"]*","PublicKey":"[^"]*","HostName":"[^"]*"' | grep -o '"HostName":"[^"]*"' | cut -d'"' -f4 || hostname)
    TAILSCALE_DOMAIN=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MagicDNSSuffix',''))" 2>/dev/null || true)
    if [ -n "$TAILSCALE_HOSTNAME" ] && [ -n "$TAILSCALE_DOMAIN" ]; then
      TAILSCALE_FQDN="${TAILSCALE_HOSTNAME}.${TAILSCALE_DOMAIN}"
      DASHBOARD_URL="https://${TAILSCALE_FQDN}:8443"
      mkdir -p "${TARGET_HOME}/.openclaw/certs"
      if tailscale cert "${TAILSCALE_FQDN}" \
          --cert-file "${TARGET_HOME}/.openclaw/certs/${TAILSCALE_FQDN}.crt" \
          --key-file  "${TARGET_HOME}/.openclaw/certs/${TAILSCALE_FQDN}.key" 2>/dev/null; then
        TAILSCALE_CERT_STATUS="issued ✅ (green lock ready)"
      else
        TAILSCALE_CERT_STATUS="cert issue failed — run: tailscale cert ${TAILSCALE_FQDN}"
        DASHBOARD_URL="https://${TAILSCALE_FQDN}:8443 (cert pending)"
      fi
    fi
  fi

  PUBLIC_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
  RESTORE_TIMESTAMP=$(date '+%Y-%m-%d %H:%M %Z')

  # ── Write NEXT_STEPS.txt ──────────────────────────────────────────────────
  NEXT_STEPS_FILE="${TARGET_HOME}/NEXT_STEPS.txt"
  cat > "$NEXT_STEPS_FILE" << NEXTSTEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TELEPORT COMPLETE — Hello from your past self 👋
  Restored: ${RESTORE_TIMESTAMP}
  Server:   $(hostname) / ${PUBLIC_IP}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

WHAT WAS RESTORED
─────────────────
  ✅ OpenClaw workspace (memories, config, tools)
  ✅ Tools Config Server  →  http://localhost:8080 (agent)
  ✅ Qdrant vector DB     →  port 6333
  ✅ Neo4j graph DB       →  port 8687
$([ -n "$TELEGRAM_TOKEN_ARG" ] && echo "  ✅ Telegram gateway    →  running (bot token provided)" || echo "  ⚠️  Telegram gateway    →  NOT started (no bot token — see below)")

TOOLS SERVER
────────────
  Agent endpoint:    http://localhost:8080   (always works, no TLS)
  Browser dashboard: ${DASHBOARD_URL}
  Password:          ${TOOLS_PASSWORD}
  Tailscale cert:    ${TAILSCALE_CERT_STATUS}

  To open dashboard via SSH tunnel (if no Tailscale):
    ssh -L 8443:localhost:8443 ${TARGET_USER}@${PUBLIC_IP}
    Then open: http://localhost:8443

$([ -z "$TELEGRAM_TOKEN_ARG" ] && cat << 'NOTOKEN'
TELEGRAM SETUP NEEDED
─────────────────────
  1. Create a new bot: @BotFather → /newbot
  2. Edit config:      nano ~/.openclaw/openclaw.json
                       → channels.telegram.token = <new-bot-token>
  3. Start gateway:    XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start openclaw-gateway
  4. Test:             Send /start to your bot in Telegram

NOTOKEN
)
NEXT STEPS
──────────
  1. SSH in:        ssh ${TARGET_USER}@${PUBLIC_IP}
  2. Change passwd: passwd
  3. Run checks:    ~/.openclaw/workspace/tools-server/agent-tools-check.sh
  4. Harden:        bash ~/.openclaw/workspace/streamliner/install/teleport/harden.sh
     (installs fail2ban, disables root SSH — run AFTER confirming SSH access works)
$([ -n "$TAILSCALE_HOSTNAME" ] && echo "  5. Tailscale:     Already detected (${TAILSCALE_FQDN})" || echo "  5. Tailscale:     Not detected — install if you want dashboard green lock")

HEALTH CHECK
────────────
$(~/.openclaw/workspace/tools-server/agent-tools-check.sh 2>/dev/null || echo "  (run manually: ~/.openclaw/workspace/tools-server/agent-tools-check.sh)")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  ONE-TIME FILE — delete after reading:  rm ~/NEXT_STEPS.txt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NEXTSTEPS

  ok "NEXT_STEPS.txt written → ${NEXT_STEPS_FILE}"

  # ── Telegram notification (best effort) ──────────────────────────────────
  TELEGRAM_BOT_TOKEN=""
  if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
    TELEGRAM_BOT_TOKEN=$(python3 -c "import json,sys; d=json.load(open('${OPENCLAW_DIR}/openclaw.json')); print(d.get('channels',{}).get('telegram',{}).get('botToken',''))" 2>/dev/null || true)
  fi

  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    TG_MSG="🚀 *Teleport complete*

Server: \`$(hostname)\` / \`${PUBLIC_IP}\`
Restored: ${RESTORE_TIMESTAMP}

*Tools server:* http://localhost:8080
*Dashboard:* ${DASHBOARD_URL}
*Password:* \`${TOOLS_PASSWORD}\`

$([ "$FAIL" -eq 0 ] && echo "✅ All checks passed" || echo "⚠️ ${FAIL} check(s) failed — see NEXT_STEPS.txt")

Full details: \`cat ~/NEXT_STEPS.txt\`"

    curl -sf --max-time 10 \
      -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=58748195" \
      -d "parse_mode=Markdown" \
      --data-urlencode "text=${TG_MSG}" \
      >/dev/null 2>&1 && ok "Telegram notification sent to Alex" \
                       || warn "Telegram notification failed (best effort — check ~/NEXT_STEPS.txt)"
  else
    warn "No Telegram token found — skipping notification (check ~/NEXT_STEPS.txt)"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}✅ Teleport complete — ${PASS}/${PASS} checks passed${NC}"
  else
    echo -e "${YELLOW}⚠️  Teleport done with warnings — ${PASS} passed, ${FAIL} failed${NC}"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  if [ "$CREATE_USER" = "true" ]; then
    echo -e "${YELLOW}👤 New user created: ${TARGET_USER}${NC}"
    echo -e "${YELLOW}   Temp password:    ${USER_TEMP_PASSWORD}${NC}"
    echo -e "${YELLOW}   Saved to:         /root/openclaw-user-password.txt (root-readable)${NC}"
    echo -e "${YELLOW}   Change with:      passwd${NC}"
    echo ""
  fi
  echo "Next steps:"
  echo "  1. SSH as ${TARGET_USER}:       ssh ${TARGET_USER}@<server-ip>"
  echo "  2. Change password:       passwd"
  if [ -n "$TELEGRAM_TOKEN_ARG" ]; then
    echo "  3. Message your bot:      Open Telegram → send /start to your bot"
    echo "  4. Confirm response:      If no reply, check: journalctl --user -u openclaw-gateway -n 30"
    echo "  5. Harden:                bash ~/.openclaw/workspace/streamliner/install/teleport/harden.sh"
  else
    echo "  3. ⚠️  Create a NEW Telegram bot via @BotFather — do NOT reuse an existing token"
    echo "  4. Update bot token:      nano ~/.openclaw/openclaw.json"
    echo "                            → channels.telegram.token = <new-bot-token>"
    echo "  5. Start gateway:         XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user start openclaw-gateway"
    echo "  6. Message your bot:      Send /start in Telegram to confirm"
    echo "  7. Harden:                bash ~/.openclaw/workspace/streamliner/install/teleport/harden.sh"
  fi
  echo "  Tools dashboard:          https://<server-ip>:8443 (password printed above)"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${YELLOW}🔒 Security hardening (run AFTER confirming everything works):${NC}"
  echo ""
  echo "  bash ${WORKSPACE_DIR}/streamliner/install/teleport/harden.sh"
  echo ""
  echo "  Installs fail2ban, recidive jail, disables root SSH login."
  echo "  Do NOT run until you have confirmed SSH access works correctly."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  exit 0
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ROOT ZONE — runs as root, handles phases 1-2 + user creation, then re-execs
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── Defaults ──────────────────────────────────────────────────────────────────
TARGET_USER="${TARGET_USER:-}"
WORKSPACE_REPO="${WORKSPACE_REPO:-https://github.com/prudkov/mel-memory.git}"
BACKUP_FILE="${BACKUP_FILE:-}"
BACKUP_KEY="${BACKUP_KEY:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
NODE_VERSION="22"
QDRANT_PORT="6333"
NEO4J_HTTP_PORT="8474"
NEO4J_BOLT_PORT="8687"
NEO4J_AUTH="neo4j/mem0graph"
CREATE_USER="false"
USER_TEMP_PASSWORD=""
TELEGRAM_TOKEN_ARG=""
TOOLS_BIND="${TOOLS_BIND:-0.0.0.0:8443}"
TOOLS_AGENT_PORT="${TOOLS_AGENT_PORT:-8080}"
TOOLS_PASSWORD="${TOOLS_PASSWORD:-}"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --backup)          BACKUP_FILE="$2";        shift 2 ;;
    --key)             BACKUP_KEY="$2";         shift 2 ;;
    --key-file)        BACKUP_KEY=$(cat "$2");  shift 2 ;;
    --github-token)    GITHUB_TOKEN="$2";       shift 2 ;;
    --user)            TARGET_USER="$2";        shift 2 ;;
    --workspace-repo)  WORKSPACE_REPO="$2";     shift 2 ;;
    --tools-bind)      TOOLS_BIND="$2";         shift 2 ;;
    --tools-password)  TOOLS_PASSWORD="$2";     shift 2 ;;
    --telegram-token)  TELEGRAM_TOKEN_ARG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate required params ──────────────────────────────────────────────────
[ -z "$BACKUP_FILE" ]    && fail "--backup <file> is required"
[ -z "$BACKUP_KEY" ]     && fail "--key <decryption-key> or --key-file <path> is required"
[ ! -f "$BACKUP_FILE" ]  && fail "Backup file not found: $BACKUP_FILE"
[ -z "$TARGET_USER" ]    && fail "--user <username> is required (do not run as root)"

if [ "$TARGET_USER" = "root" ]; then
  fail "--user root is not allowed. Specify a non-root username (e.g. --user alex)"
fi

if [ "$(whoami)" != "root" ]; then
  fail "This script must run as root"
fi

# Generate tools password if not provided
[ -z "$TOOLS_PASSWORD" ] && TOOLS_PASSWORD=$(openssl rand -hex 16)

# ── Create user if needed ─────────────────────────────────────────────────────
if ! id "$TARGET_USER" &>/dev/null; then
  CREATE_USER="true"
  USER_TEMP_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | cut -c1-20)
  useradd -m -s /bin/bash "$TARGET_USER"
  echo "${TARGET_USER}:${USER_TEMP_PASSWORD}" | chpasswd
  usermod -aG docker "$TARGET_USER" 2>/dev/null || true
  usermod -aG sudo "$TARGET_USER"
  loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
  echo "${USER_TEMP_PASSWORD}" > /root/openclaw-user-password.txt
  chmod 600 /root/openclaw-user-password.txt
  echo -e "${GREEN}[OK]${NC}    User '${TARGET_USER}' created (temp password saved to /root/openclaw-user-password.txt)"
else
  usermod -aG docker "$TARGET_USER" 2>/dev/null || true
  loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
  echo -e "${GREEN}[OK]${NC}    User '${TARGET_USER}' exists"
fi

TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
OPENCLAW_DIR="${TARGET_HOME}/.openclaw"

TARGET_HOME_DISPLAY="${TARGET_HOME}"
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║               🚀 OpenClaw Teleport Restore                          ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  User:         %-53s ║\n" "$TARGET_USER"
printf "║  OpenClaw dir: %-53s ║\n" "${TARGET_HOME_DISPLAY}/.openclaw"
printf "║  Workspace:    %-53s ║\n" "$WORKSPACE_REPO"
printf "║  Backup:       %-53s ║\n" "$(basename "$BACKUP_FILE")"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Phase 1/11: System dependencies ──────────────────────────────────────────
phase "1/11 — System dependencies"

apt-get update -qq
apt-get install -y -qq \
  curl git jq gpg unzip wget python3 python3-pip \
  ca-certificates gnupg lsb-release sshpass > /dev/null
ok "Base packages installed"

# Docker
if ! command -v docker &>/dev/null; then
  info "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null
  systemctl enable docker --now
  ok "Docker installed"
else
  ok "Docker already installed: $(docker --version | cut -d' ' -f3)"
fi

# Node.js
if ! command -v node &>/dev/null || [ "$(node --version | cut -dv -f2 | cut -d. -f1)" -lt "$NODE_VERSION" ]; then
  info "Installing Node.js ${NODE_VERSION}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null
  ok "Node.js $(node --version) installed"
else
  ok "Node.js $(node --version) already installed"
fi

# ── Phase 2/11: Start Docker containers ──────────────────────────────────────
phase "2/11 — Docker containers (Qdrant + Neo4j)"

mkdir -p "${OPENCLAW_DIR}/qdrant-storage" "${OPENCLAW_DIR}/neo4j-data"
chown -R "${TARGET_USER}:${TARGET_USER}" "${OPENCLAW_DIR}" 2>/dev/null || true

# Qdrant
if ! docker ps --format '{{.Names}}' | grep -q "^qdrant$"; then
  info "Starting Qdrant..."
  docker run -d \
    --name qdrant \
    --restart unless-stopped \
    -p ${QDRANT_PORT}:6333 \
    -v "${OPENCLAW_DIR}/qdrant-storage:/qdrant/storage" \
    qdrant/qdrant:latest > /dev/null
  ok "Qdrant container started"
else
  ok "Qdrant already running"
fi

# Neo4j
if ! docker ps --format '{{.Names}}' | grep -q "^neo4j-mem0$"; then
  info "Starting Neo4j..."
  docker run -d \
    --name neo4j-mem0 \
    --restart unless-stopped \
    -p ${NEO4J_HTTP_PORT}:7474 \
    -p ${NEO4J_BOLT_PORT}:7687 \
    -e NEO4J_AUTH="${NEO4J_AUTH}" \
    -v "${OPENCLAW_DIR}/neo4j-data:/data" \
    neo4j:5.26.4-community > /dev/null
  ok "Neo4j container started"
else
  ok "Neo4j already running"
fi

# Wait for containers to be healthy
info "Waiting for Qdrant to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${QDRANT_PORT}/readyz" > /dev/null 2>&1; then
    ok "Qdrant ready"
    break
  fi
  sleep 2
  [ $i -eq 30 ] && fail "Qdrant did not become ready after 60s"
done

info "Waiting for Neo4j to be ready..."
for i in $(seq 1 45); do
  if curl -sf "http://localhost:${NEO4J_HTTP_PORT}" > /dev/null 2>&1; then
    ok "Neo4j ready"
    break
  fi
  sleep 3
  [ $i -eq 45 ] && fail "Neo4j did not become ready after 135s"
done

# ── Copy backup to /tmp so target user can read it ────────────────────────────
BACKUP_TMP="/tmp/teleport-backup-$$.gpg"
cp "$BACKUP_FILE" "$BACKUP_TMP"
chmod 644 "$BACKUP_TMP"

# ── Write env file for user zone ──────────────────────────────────────────────
ENV_FILE="/tmp/teleport-env-$$.sh"
# Use printf %q for safe quoting of values that may contain special chars
{
  printf 'TARGET_USER=%q\n'        "$TARGET_USER"
  printf 'TARGET_HOME=%q\n'        "$TARGET_HOME"
  printf 'WORKSPACE_REPO=%q\n'     "$WORKSPACE_REPO"
  printf 'BACKUP_TMP=%q\n'         "$BACKUP_TMP"
  printf 'BACKUP_KEY=%q\n'         "$BACKUP_KEY"
  printf 'GITHUB_TOKEN=%q\n'       "$GITHUB_TOKEN"
  printf 'NODE_VERSION=%q\n'       "$NODE_VERSION"
  printf 'QDRANT_PORT=%q\n'        "$QDRANT_PORT"
  printf 'NEO4J_HTTP_PORT=%q\n'    "$NEO4J_HTTP_PORT"
  printf 'NEO4J_BOLT_PORT=%q\n'    "$NEO4J_BOLT_PORT"
  printf 'NEO4J_AUTH=%q\n'         "$NEO4J_AUTH"
  printf 'CREATE_USER=%q\n'        "$CREATE_USER"
  printf 'USER_TEMP_PASSWORD=%q\n' "$USER_TEMP_PASSWORD"
  printf 'TELEGRAM_TOKEN_ARG=%q\n' "$TELEGRAM_TOKEN_ARG"
  printf 'TOOLS_BIND=%q\n'         "$TOOLS_BIND"
  printf 'TOOLS_AGENT_PORT=%q\n'   "$TOOLS_AGENT_PORT"
  printf 'TOOLS_PASSWORD=%q\n'     "$TOOLS_PASSWORD"
} > "$ENV_FILE"
chmod 644 "$ENV_FILE"

# ── Re-exec as target user ────────────────────────────────────────────────────
info "Handing off to user zone (running as ${TARGET_USER})..."
SCRIPT_COPY="/tmp/teleport-restore-$$.sh"
cp "$(realpath "$0")" "$SCRIPT_COPY"
chmod 755 "$SCRIPT_COPY"
su - "${TARGET_USER}" -s /bin/bash -c "bash '$SCRIPT_COPY' --user-phase '$ENV_FILE'"
rm -f "$SCRIPT_COPY"
EXIT_CODE=$?

# Cleanup root-side temp files (user zone cleans its own copies on EXIT trap)
rm -f "$BACKUP_TMP" "$ENV_FILE"

exit $EXIT_CODE
