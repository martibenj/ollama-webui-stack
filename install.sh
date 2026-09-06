#!/usr/bin/env bash
# Installs Ollama + Open WebUI + SearXNG as three Docker containers managed by systemd,
# all sharing a common Docker network ("app-net"), with Ollama exposed on 0.0.0.0:11434.
#
# Requires an NVIDIA GPU (installs nvidia-container-toolkit automatically).
#
# Usage:
#   sudo ./install.sh
#   sudo ./install.sh --uninstall

set -euo pipefail

CONFIG_DIR="/etc/ollama-webui-stack"
SEARXNG_CONFIG_DIR="$CONFIG_DIR/searxng"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNINSTALL=false

for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo ./install.sh ...)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
if $UNINSTALL; then
  echo "== Stopping and disabling services =="
  for svc in ollama open-webui searxng; do
    systemctl disable --now "$svc".service 2>/dev/null || true
  done
  echo "Stopped and disabled: ollama, open-webui, searxng"

  echo "== Removing systemd units =="
  rm -f /etc/systemd/system/ollama.service /etc/systemd/system/open-webui.service /etc/systemd/system/searxng.service
  systemctl daemon-reload
  echo "Removed unit files and reloaded systemd."

  echo "== Removing containers (in case they're still around) =="
  docker rm -f ollama open-webui searxng 2>/dev/null || true
  echo "Containers removed (if they existed)."

  echo "== Removing Docker network =="
  docker network rm app-net 2>/dev/null || true
  echo "Removed network: app-net"

  echo "== Removing config directory =="
  rm -rf "$CONFIG_DIR"
  echo "Removed: $CONFIG_DIR"

  echo "== Removing volumes (Open WebUI data + Ollama models) =="
  docker volume rm open-webui ollama-models 2>/dev/null || true
  echo "Removed volumes: open-webui, ollama-models"

  echo "== Uninstall complete =="
  exit 0
fi

# ---------------------------------------------------------------------------
# Install path
# ---------------------------------------------------------------------------

command -v nvidia-smi >/dev/null || {
  # WSL note: nvidia-smi often lives in /usr/lib/wsl/lib, which sudo's
  # secure_path may exclude even though it works fine for the normal user.
  if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
    export PATH="$PATH:/usr/lib/wsl/lib"
  fi
}

command -v nvidia-smi >/dev/null || {
  echo "nvidia-smi not found — this repo targets NVIDIA GPU setups only." >&2
  echo "Install NVIDIA drivers first, or adapt ollama.service manually for CPU-only use." >&2
  echo "(On WSL: if 'nvidia-smi' works without sudo but not with it, symlink it into" >&2
  echo " a path sudo trusts, e.g.: sudo ln -s \$(which nvidia-smi) /usr/local/bin/nvidia-smi)" >&2
  exit 1
}

command -v docker >/dev/null || { echo "Docker is required but not found." >&2; exit 1; }

echo "== Checking repo files =="
for f in ollama.service open-webui.service searxng.service searxng-settings.yml; do
  if [[ ! -f "$REPO_DIR/$f" ]]; then
    echo "ERROR: missing '$f' in $REPO_DIR — aborting before touching anything." >&2
    exit 1
  fi
done
echo "All required files found in $REPO_DIR."

echo "== Resetting config directories =="
rm -rf "$CONFIG_DIR"
mkdir -p "$CONFIG_DIR" "$SEARXNG_CONFIG_DIR"
echo "Config directories (re)created:"
echo "  * $CONFIG_DIR"
echo "  * $SEARXNG_CONFIG_DIR"

echo "== Writing SearXNG settings =="
cp "$REPO_DIR/searxng-settings.yml" "$SEARXNG_CONFIG_DIR/settings.yml"
SECRET=$(openssl rand -hex 32)
sed -i "s/REPLACE_ME/$SECRET/" "$SEARXNG_CONFIG_DIR/settings.yml"
echo "SearXNG settings written to $SEARXNG_CONFIG_DIR/settings.yml (new random secret_key generated)."

echo "== Writing Open WebUI secret =="
echo "WEBUI_SECRET_KEY=$(openssl rand -hex 32)" > "$CONFIG_DIR/webui.env"
chmod 600 "$CONFIG_DIR/webui.env"
echo "New Open WebUI secret written to $CONFIG_DIR/webui.env (any existing Open WebUI sessions will be invalidated)."

echo "== Installing NVIDIA Container Toolkit =="
if ! command -v nvidia-ctk >/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  echo "NVIDIA Container Toolkit installed and Docker configured for GPU access."
else
  echo "nvidia-ctk already installed at $(command -v nvidia-ctk), skipping installation."
fi

echo "== Creating Docker network and volume =="
docker network create app-net 2>/dev/null || true
docker volume create ollama-models >/dev/null
echo "Docker network ready: app-net"
echo "Docker volume ready:  ollama-models (kept across re-runs — models are never wiped by this script)"

echo "== Resetting systemd units =="
rm -f /etc/systemd/system/ollama.service /etc/systemd/system/open-webui.service /etc/systemd/system/searxng.service
cp "$REPO_DIR/ollama.service" /etc/systemd/system/ollama.service
cp "$REPO_DIR/open-webui.service" /etc/systemd/system/open-webui.service
cp "$REPO_DIR/searxng.service" /etc/systemd/system/searxng.service
echo "Units (re)installed:"
echo "  * /etc/systemd/system/ollama.service"
echo "  * /etc/systemd/system/open-webui.service"
echo "  * /etc/systemd/system/searxng.service"

echo "== Restarting containers =="
systemctl daemon-reload

echo "== Restarting ollama (can take a few minutes...) =="
systemctl enable --now ollama.service
echo "ollama started."

echo "== Restarting searxng (can take a few minutes...) =="
systemctl enable --now searxng.service
echo "searxng started."

echo "== Restarting open-webui (can take a few minutes...) =="
systemctl enable --now open-webui.service
echo "open-webui started."
echo "Services (re)started: ollama, searxng, open-webui"

echo "== Done =="
echo "Open WebUI:  http://localhost:3100"
echo "Ollama API:  http://localhost:11434"
echo "Check status with: systemctl status ollama open-webui searxng"