#!/usr/bin/env bash
# Streamliner One full installer for Tools Config Server
set -euo pipefail

APP_NAME="tools-config-server"
INSTALL_ROOT="/opt/streamliner"
APP_DIR="$INSTALL_ROOT/$APP_NAME"
SERVICE_NAME="tools-config-server"
REPO_TARBALL_DEFAULT="https://github.com/Streamliner-One/tools-config-server/archive/refs/heads/main.tar.gz"
BIND_DEFAULT="0.0.0.0:8443"

log(){ echo "[install] $*"; }
err(){ echo "[install][error] $*" >&2; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }

is_root(){ [ "${EUID:-$(id -u)}" -eq 0 ]; }

if ! is_root; then
  err "Please run as root (or with sudo): curl -fsSL https://install.streamliner.one | sudo bash"
  exit 1
fi

need_cmd curl
need_cmd tar
need_cmd systemctl

# Detect package manager + install deps
install_deps(){
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing dependencies via apt..."
    apt-get update -y
    apt-get install -y ca-certificates curl git jq tar
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing dependencies via dnf..."
    dnf install -y ca-certificates curl git jq tar
  elif command -v yum >/dev/null 2>&1; then
    log "Installing dependencies via yum..."
    yum install -y ca-certificates curl git jq tar
  else
    err "Unsupported package manager. Install: curl git jq tar"
    exit 1
  fi
}

install_node(){
  if command -v node >/dev/null 2>&1; then
    local major
    major=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$major" -ge 18 ]; then
      log "Node.js already installed: $(node -v)"
      return
    fi
  fi

  log "Installing Node.js 20..."
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  elif command -v dnf >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    dnf install -y nodejs
  elif command -v yum >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
    yum install -y nodejs
  fi

  log "Node installed: $(node -v)"
}

resolve_tarball(){
  if [ -n "${TOOLS_CONFIG_TARBALL_URL:-}" ]; then
    echo "$TOOLS_CONFIG_TARBALL_URL"
    return
  fi

  local versions_url="https://raw.githubusercontent.com/Streamliner-One/install/main/versions.json"
  local channel="${INSTALL_CHANNEL:-stable}"
  local url
  url=$(curl -fsSL "$versions_url" | jq -r --arg c "$channel" '.channels[$c].artifact_url // empty' || true)
  if [ -n "$url" ]; then
    echo "$url"
  else
    echo "$REPO_TARBALL_DEFAULT"
  fi
}

setup_dirs(){
  mkdir -p "$APP_DIR"
  mkdir -p /var/lib/tools-config-server
  mkdir -p /var/log/tools-config-server
}

download_and_extract(){
  local tarball_url="$1"
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  log "Downloading artifact: $tarball_url"
  curl -fL "$tarball_url" -o "$tmp/app.tar.gz"

  rm -rf "$APP_DIR"/*
  mkdir -p "$APP_DIR"

  log "Extracting..."
  tar -xzf "$tmp/app.tar.gz" -C "$tmp"

  # Handle GitHub archive structure: repo-main/
  local extracted
  extracted=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)

  # If repo root has tools-server/ use it; else use root
  if [ -d "$extracted/tools-server" ]; then
    cp -a "$extracted/tools-server/." "$APP_DIR/"
  else
    cp -a "$extracted/." "$APP_DIR/"
  fi

  if [ ! -f "$APP_DIR/server.js" ]; then
    err "server.js not found after extraction"
    exit 1
  fi
}

install_app(){
  log "Installing npm dependencies..."
  cd "$APP_DIR"
  npm install --production
}

generate_password(){
  if [ -n "${TOOLS_CONFIG_PASSWORD:-}" ]; then
    echo "$TOOLS_CONFIG_PASSWORD"
  else
    openssl rand -hex 16
  fi
}

write_env(){
  local pass="$1"
  local bind="${TOOLS_CONFIG_BIND:-$BIND_DEFAULT}"
  cat > /etc/default/tools-config-server <<ENV
TOOLS_CONFIG_PASSWORD=${pass}
TOOLS_CONFIG_BIND=${bind}
TOOLS_CONFIG_HTTPS=1
ENV
  chmod 600 /etc/default/tools-config-server
}

write_service(){
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<'UNIT'
[Unit]
Description=Tools Config Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/streamliner/tools-config-server
EnvironmentFile=/etc/default/tools-config-server
ExecStart=/usr/bin/env bash -lc 'node server.js --bind "$TOOLS_CONFIG_BIND" --password "$TOOLS_CONFIG_PASSWORD" --https'
Restart=always
RestartSec=3
StandardOutput=append:/var/log/tools-config-server/server.log
StandardError=append:/var/log/tools-config-server/server.log

[Install]
WantedBy=multi-user.target
UNIT
}

start_service(){
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  sleep 2
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

main(){
  install_deps
  install_node
  setup_dirs

  local tarball
  tarball=$(resolve_tarball)
  download_and_extract "$tarball"
  install_app

  local pass
  pass=$(generate_password)
  write_env "$pass"
  write_service
  start_service

  local bind
  bind=$(grep '^TOOLS_CONFIG_BIND=' /etc/default/tools-config-server | cut -d= -f2-)

  echo
  echo "✅ Tools Config Server installed"
  echo "   Service: $SERVICE_NAME"
  echo "   Bind:    $bind"
  echo "   URL:     https://<server-ip>:${bind##*:}"
  echo "   Password: $pass"
  echo
  echo "Commands:"
  echo "  systemctl status $SERVICE_NAME"
  echo "  journalctl -u $SERVICE_NAME -f"
}

main "$@"
