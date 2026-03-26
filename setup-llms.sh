#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# local-llm-stack setup (CPU-first, laptop-friendly)
#
# Installs:
#   - llama-swap
#   - vLLM (user-local virtualenv)
#
# Configures:
#   - llama-swap in front of vLLM
#   - models:
#       * qwen-coder-1.5b  -> Qwen/Qwen2.5-Coder-1.5B-Instruct-GPTQ-Int4
#       * gemma3-1b        -> google/gemma-3-1b-it
#       * qwen-coder-3b    -> Qwen/Qwen2.5-Coder-3B-Instruct-GPTQ-Int4
#
# Port block policy:
#   - prefer 50000..50003
#   - else 50100..50103
#   - else 50200..50203
#   - etc.
#
# Layout:
#   base     -> llama-swap
#   base + 1 -> qwen-coder-1.5b
#   base + 2 -> gemma3-1b
#   base + 3 -> qwen-coder-3b
#
# Service:
#   - systemd user service
#   - hardened
#   - no new privileges
#
# Notes:
#   - CPU-oriented
#   - no prompt-size autorouter
#   - quantization only for models above 1B
# ============================================================

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

if [[ "$(id -u)" -eq 0 ]]; then
  err "Run this as your normal user, not root."
  exit 1
fi

BASE_DIR="${HOME}/.local/share/local-llm-stack"
BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${BASE_DIR}/config"
VENV_DIR="${BASE_DIR}/venv"

STATE_DIR="${HOME}/.local/state/local-llm-stack"
RUNTIME_DIR="${STATE_DIR}/runtime"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/local-llm-stack.service"

ENV_FILE="${CFG_DIR}/env.sh"
LAUNCHER_FILE="${BIN_DIR}/local-llm-stack-launcher"
VLLM_WRAPPER="${BIN_DIR}/vllm-local"
LLAMA_SWAP_BIN="${BIN_DIR}/llama-swap"

PORTS_FILE="${RUNTIME_DIR}/ports.env"
LLAMA_SWAP_CFG="${RUNTIME_DIR}/llama-swap.yaml"

MODEL_QWEN15="Qwen/Qwen2.5-Coder-1.5B-Instruct-GPTQ-Int4"
MODEL_GEMMA1="google/gemma-3-1b-it"
MODEL_QWEN3="Qwen/Qwen2.5-Coder-3B-Instruct-GPTQ-Int4"

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
      err "Unsupported architecture: $m"
      exit 1
      ;;
  esac
}

detect_distro() {
  if [[ ! -f /etc/os-release ]]; then
    err "Cannot detect distro: /etc/os-release not found"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
}

setup_pkg_manager() {
  case "${DISTRO_ID}" in
    ubuntu|debian|linuxmint|pop)
      PKG_MODE="apt"
      ;;
    fedora)
      PKG_MODE="dnf"
      ;;
    rocky|rhel|almalinux|centos)
      if need_cmd dnf; then
        PKG_MODE="dnf"
      elif need_cmd yum; then
        PKG_MODE="yum"
      else
        err "No supported package manager found"
        exit 1
      fi
      ;;
    arch|manjaro|endeavouros)
      PKG_MODE="pacman"
      ;;
    opensuse*|sles)
      PKG_MODE="zypper"
      ;;
    *)
      case "${DISTRO_LIKE}" in
        *debian*) PKG_MODE="apt" ;;
        *rhel*|*fedora*)
          if need_cmd dnf; then
            PKG_MODE="dnf"
          elif need_cmd yum; then
            PKG_MODE="yum"
          else
            err "No supported package manager found"
            exit 1
          fi
          ;;
        *arch*) PKG_MODE="pacman" ;;
        *suse*) PKG_MODE="zypper" ;;
        *)
          err "Unsupported distro: ${DISTRO_ID}"
          exit 1
          ;;
      esac
      ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -eq 0 ]] && return 0

  if ! need_cmd sudo; then
    err "sudo is required to install system packages"
    exit 1
  fi

  case "${PKG_MODE}" in
    apt)
      sudo apt-get update
      sudo apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      sudo dnf install -y "${pkgs[@]}"
      ;;
    yum)
      sudo yum install -y "${pkgs[@]}"
      ;;
    pacman)
      sudo pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      sudo zypper --non-interactive install "${pkgs[@]}"
      ;;
    *)
      err "Unknown package manager: ${PKG_MODE}"
      exit 1
      ;;
  esac
}

install_system_packages() {
  local pkgs=()

  case "${PKG_MODE}" in
    apt)
      pkgs=(curl git jq tar unzip python3 python3-venv python3-pip ca-certificates)
      ;;
    dnf|yum)
      pkgs=(curl git jq tar unzip python3 python3-pip python3-virtualenv ca-certificates)
      ;;
    pacman)
      pkgs=(curl git jq tar unzip python python-pip ca-certificates)
      ;;
    zypper)
      pkgs=(curl git jq tar unzip python3 python3-pip python3-virtualenv ca-certificates)
      ;;
  esac

  log "Installing system packages..."
  pkg_install "${pkgs[@]}"
}

ensure_dirs() {
  mkdir -p \
    "${BIN_DIR}" \
    "${CFG_DIR}" \
    "${STATE_DIR}" \
    "${RUNTIME_DIR}" \
    "${SYSTEMD_USER_DIR}" \
    "${HOME}/.cache/huggingface" \
    "${HOME}/.local/share"
}

install_llama_swap() {
  log "Installing latest llama-swap release..."
  detect_arch

  local tmpdir api_url asset_url found
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN

  api_url="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"
  curl -fsSL "${api_url}" -o "${tmpdir}/release.json"

  asset_url="$(
    jq -r --arg arch "${ARCH}" '
      .assets[]
      | select(
          (.name | test("linux"; "i")) and
          (.name | test($arch; "i")) and
          (.name | (endswith(".tar.gz") or endswith(".tgz") or endswith(".zip")))
        )
      | .browser_download_url
    ' "${tmpdir}/release.json" | head -n1
  )"

  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    err "Could not find a matching llama-swap release asset for Linux ${ARCH}"
    exit 1
  fi

  log "Downloading ${asset_url}"
  curl -fL "${asset_url}" -o "${tmpdir}/llama-swap.pkg"

  case "${asset_url}" in
    *.tar.gz|*.tgz)
      tar -xzf "${tmpdir}/llama-swap.pkg" -C "${tmpdir}"
      ;;
    *.zip)
      unzip -q "${tmpdir}/llama-swap.pkg" -d "${tmpdir}"
      ;;
    *)
      err "Unsupported archive type for llama-swap asset"
      exit 1
      ;;
  esac

  found="$(find "${tmpdir}" -type f -name "llama-swap" | head -n1)"
  if [[ -z "${found}" ]]; then
    err "Could not find llama-swap binary after extraction"
    exit 1
  fi

  install -m 0755 "${found}" "${LLAMA_SWAP_BIN}"
  log "Installed llama-swap to ${LLAMA_SWAP_BIN}"
}

install_vllm() {
  log "Installing vLLM into user-local virtualenv..."
  if [[ ! -d "${VENV_DIR}" ]]; then
    python3 -m venv "${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip wheel setuptools
  python -m pip install --upgrade vllm

  cat > "${VLLM_WRAPPER}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${VENV_DIR}/bin/activate"
exec vllm "\$@"
EOF
  chmod 0755 "${VLLM_WRAPPER}"
}

write_env_file() {
  cat > "${ENV_FILE}" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash

export PATH="${BIN_DIR}:\$PATH"
export HF_HOME="\${HF_HOME:-${HOME}/.cache/huggingface}"
export VLLM_USE_V1="\${VLLM_USE_V1:-1}"

# Needed for gated models like Gemma:
# export HF_TOKEN="hf_xxx"

# CPU-friendly context limits
export QWEN15_CTX="\${QWEN15_CTX:-8192}"
export GEMMA1_CTX="\${GEMMA1_CTX:-4096}"
export QWEN3_CTX="\${QWEN3_CTX:-12288}"

# Optional CPU tuning:
# export VLLM_CPU_KVCACHE_SPACE="8"
# export VLLM_CPU_OMP_THREADS_BIND="0-7"
EOF
  chmod 0644 "${ENV_FILE}"
}

write_launcher() {
  cat > "${LAUNCHER_FILE}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${HOME}/.local/share/local-llm-stack"
BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${BASE_DIR}/config"
STATE_DIR="${HOME}/.local/state/local-llm-stack"
RUNTIME_DIR="${STATE_DIR}/runtime"

ENV_FILE="${CFG_DIR}/env.sh"
PORTS_FILE="${RUNTIME_DIR}/ports.env"
LLAMA_SWAP_CFG="${RUNTIME_DIR}/llama-swap.yaml"

LLAMA_SWAP_BIN="${BIN_DIR}/llama-swap"
VLLM_WRAPPER="${BIN_DIR}/vllm-local"

MODEL_QWEN15="Qwen/Qwen2.5-Coder-1.5B-Instruct-GPTQ-Int4"
MODEL_GEMMA1="google/gemma-3-1b-it"
MODEL_QWEN3="Qwen/Qwen2.5-Coder-3B-Instruct-GPTQ-Int4"

mkdir -p "${RUNTIME_DIR}" "${HOME}/.cache/huggingface"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

choose_port_block() {
  python3 - <<'PY'
import socket
import sys

def block_free(base: int) -> bool:
    socks = []
    try:
        for port in [base, base + 1, base + 2, base + 3]:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", port))
            socks.append(s)
        return True
    except OSError:
        return False
    finally:
        for s in socks:
            try:
                s.close()
            except Exception:
                pass

for base in range(50000, 65000, 100):
    if block_free(base):
        print(base)
        sys.exit(0)

sys.exit(1)
PY
}

BASE_PORT="$(choose_port_block)"
if [[ -z "${BASE_PORT}" ]]; then
  echo "No free port block found starting at 50000, 50100, 50200, ..." >&2
  exit 1
fi

LLAMA_SWAP_PORT="${BASE_PORT}"
QWEN15_PORT="$((BASE_PORT + 1))"
GEMMA1_PORT="$((BASE_PORT + 2))"
QWEN3_PORT="$((BASE_PORT + 3))"

cat > "${PORTS_FILE}" <<PORTS
BASE_PORT=${BASE_PORT}
LLAMA_SWAP_PORT=${LLAMA_SWAP_PORT}
QWEN15_PORT=${QWEN15_PORT}
GEMMA1_PORT=${GEMMA1_PORT}
QWEN3_PORT=${QWEN3_PORT}
PORTS

cat > "${LLAMA_SWAP_CFG}" <<YAML
healthCheckTimeout: 300
logLevel: info
logToStdout: proxy

models:
  qwen-coder-1.5b:
    proxy: http://127.0.0.1:${QWEN15_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_TOKEN
      - HF_HOME
      - VLLM_USE_V1
      - VLLM_CPU_KVCACHE_SPACE
      - VLLM_CPU_OMP_THREADS_BIND
    cmd: |
      ${VLLM_WRAPPER} serve ${MODEL_QWEN15} \
        --host 127.0.0.1 \
        --port ${QWEN15_PORT} \
        --served-model-name qwen-coder-1.5b \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${QWEN15_CTX:-8192}

  gemma3-1b:
    proxy: http://127.0.0.1:${GEMMA1_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_TOKEN
      - HF_HOME
      - VLLM_USE_V1
      - VLLM_CPU_KVCACHE_SPACE
      - VLLM_CPU_OMP_THREADS_BIND
    cmd: |
      ${VLLM_WRAPPER} serve ${MODEL_GEMMA1} \
        --host 127.0.0.1 \
        --port ${GEMMA1_PORT} \
        --served-model-name gemma3-1b \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${GEMMA1_CTX:-4096}

  qwen-coder-3b:
    proxy: http://127.0.0.1:${QWEN3_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_TOKEN
      - HF_HOME
      - VLLM_USE_V1
      - VLLM_CPU_KVCACHE_SPACE
      - VLLM_CPU_OMP_THREADS_BIND
    cmd: |
      ${VLLM_WRAPPER} serve ${MODEL_QWEN3} \
        --host 127.0.0.1 \
        --port ${QWEN3_PORT} \
        --served-model-name qwen-coder-3b \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${QWEN3_CTX:-12288}
YAML

exec "${LLAMA_SWAP_BIN}" -listen "127.0.0.1:${LLAMA_SWAP_PORT}" -config "${LLAMA_SWAP_CFG}"
EOF
  chmod 0755 "${LAUNCHER_FILE}"
}

write_systemd_user_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Local LLM stack (llama-swap + vLLM backends, CPU-first)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${LAUNCHER_FILE}
Restart=on-failure
RestartSec=3
TimeoutStopSec=60

NoNewPrivileges=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077

ProtectSystem=full
ReadWritePaths=${BASE_DIR} ${STATE_DIR} ${HOME}/.cache/huggingface ${HOME}/.local/share

[Install]
WantedBy=default.target
EOF
}

print_notes() {
  cat <<EOF

Done.

Installed:
  llama-swap:   ${LLAMA_SWAP_BIN}
  vLLM wrapper: ${VLLM_WRAPPER}

Config:
  ${ENV_FILE}

Service:
  ${SERVICE_FILE}

Runtime state:
  ${RUNTIME_DIR}

Enable and start:
  systemctl --user daemon-reload
  systemctl --user enable --now local-llm-stack

Check status:
  systemctl --user status local-llm-stack
  journalctl --user -u local-llm-stack -f

Chosen ports after start:
  ${PORTS_FILE}

Health test:
  source "${PORTS_FILE}"
  curl "http://127.0.0.1:\${LLAMA_SWAP_PORT}/health"

List models:
  source "${PORTS_FILE}"
  curl "http://127.0.0.1:\${LLAMA_SWAP_PORT}/v1/models"

Chat test:
  source "${PORTS_FILE}"
  curl "http://127.0.0.1:\${LLAMA_SWAP_PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
      "model": "qwen-coder-1.5b",
      "messages": [{"role": "user", "content": "Write hello world in Go."}]
    }'

Important:
  - Gemma is gated on Hugging Face. Set HF_TOKEN in:
      ${ENV_FILE}
  - Context is deliberately capped lower than model max for laptop/CPU friendliness.
EOF
}

main() {
  detect_distro
  setup_pkg_manager
  install_system_packages
  ensure_dirs
  install_llama_swap
  install_vllm
  write_env_file
  write_launcher
  write_systemd_user_service

  systemctl --user daemon-reload || true

  print_notes

  if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "HF_TOKEN is not set in this shell. Qwen can still work; Gemma will not download until HF_TOKEN is added to ${ENV_FILE}."
  fi

  warn "This script assumes your platform can install vLLM from pip. Some CPU environments may still need a source-build or container-based vLLM setup."
}

main "$@"