#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# local-llm-stack setup (CPU-first, laptop-friendly)
#
# Defau([docs.vllm.ai](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/?utm_source=chatgpt.com))
# Optional backend:
#   - vLLM (disabled by default, installed into its own venv only)
#
# Front router:
#   - llama-swap
#
# Default models (GGUF via llama.cpp, auto-fetched by llama-server):
#   * qwen-coder-1.5b  -> Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M
#   * gemma3-1b        -> google/gemma-3-1b-it-qat-q4_0-gguf
#   * qwen-coder-3b    -> Qwen/Qwen2.5-Coder-3B-Instruct-GGUF:Q4_K_M
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
# Notes:
#   - run as normal user, not root
#   - CPU-first, minimal global pollution
#   - Python only used for helper logic and optional vLLM venv
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
SRC_DIR="${BASE_DIR}/src"
VENV_DIR="${BASE_DIR}/venv/vllm"

STATE_DIR="${HOME}/.local/state/local-llm-stack"
RUNTIME_DIR="${STATE_DIR}/runtime"
LOG_DIR="${STATE_DIR}/log"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/local-llm-stack.service"

ENV_FILE="${CFG_DIR}/env.sh"
LAUNCHER_FILE="${BIN_DIR}/local-llm-stack-launcher"
VLLM_WRAPPER="${BIN_DIR}/vllm-local"
LLAMA_SWAP_BIN="${BIN_DIR}/llama-swap"
LLAMA_SERVER_BIN="${BIN_DIR}/llama-server"

PORTS_FILE="${RUNTIME_DIR}/ports.env"
LLAMA_SWAP_CFG="${RUNTIME_DIR}/llama-swap.yaml"

# Human-friendly aliases exposed through llama-swap
ALIAS_QWEN15="qwen-coder-1.5b"
ALIAS_GEMMA1="gemma3-1b"
ALIAS_QWEN3="qwen-coder-3b"

# Defaults are intentionally overrideable in env.sh
DEFAULT_QWEN15_REPO="Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF"
DEFAULT_QWEN15_QUANT="Q4_K_M"

DEFAULT_GEMMA1_REPO="google/gemma-3-1b-it-qat-q4_0-gguf"
DEFAULT_GEMMA1_QUANT=""

DEFAULT_QWEN3_REPO="Qwen/Qwen2.5-Coder-3B-Instruct-GGUF"
DEFAULT_QWEN3_QUANT="Q4_K_M"

VLLM_ENABLED="${VLLM_ENABLED:-0}"

ARCH=""
DISTRO_ID=""
DISTRO_LIKE=""
PKG_MODE=""

cleanup_tmpdir() {
  if [[ -n "${TMPDIR_CREATED:-}" && -d "${TMPDIR_CREATED}" ]]; then
    rm -rf "${TMPDIR_CREATED}"
  fi
}
trap cleanup_tmpdir EXIT

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
      pkgs=(curl git jq tar unzip python3 python3-venv python3-pip ca-certificates build-essential cmake pkg-config)
      ;;
    dnf|yum)
      pkgs=(curl git jq tar unzip python3 python3-pip python3-virtualenv ca-certificates gcc gcc-c++ make cmake pkgconf-pkg-config)
      ;;
    pacman)
      pkgs=(curl git jq tar unzip python python-pip ca-certificates base-devel cmake pkgconf)
      ;;
    zypper)
      pkgs=(curl git jq tar unzip python3 python3-pip python3-virtualenv ca-certificates gcc gcc-c++ make cmake pkg-config)
      ;;
  esac

  log "Installing system packages..."
  pkg_install "${pkgs[@]}"
}

ensure_dirs() {
  mkdir -p \
    "${BIN_DIR}" \
    "${CFG_DIR}" \
    "${SRC_DIR}" \
    "${STATE_DIR}" \
    "${RUNTIME_DIR}" \
    "${LOG_DIR}" \
    "${SYSTEMD_USER_DIR}" \
    "${HOME}/.cache/huggingface" \
    "${HOME}/.local/share"
}

preflight_checks() {
  log "Running preflight checks..."

  if ! need_cmd systemctl; then
    err "systemctl not found. This script expects a systemd-based user environment."
    exit 1
  fi

  if ! systemctl --user --version >/dev/null 2>&1; then
    warn "systemctl --user is not fully available in this shell right now. The service file will still be written."
  fi

  if ! need_cmd python3; then
    err "python3 is required"
    exit 1
  fi

  if ! need_cmd git; then
    err "git is required"
    exit 1
  fi

  if ! need_cmd curl; then
    err "curl is required"
    exit 1
  fi

  log "Host summary:"
  uname -a || true
  python3 --version || true
  if need_cmd gcc; then gcc --version | head -n1 || true; fi
  if need_cmd lscpu; then
    lscpu | sed -n '1,20p' || true
    if lscpu | grep -qi 'avx512'; then
      log "AVX512 detected. Good for CPU inference workloads."
    else
      warn "AVX512 not detected. CPU inference still works, but throughput may be lower."
    fi
  fi
}

install_llama_swap() {
  log "Installing latest llama-swap release..."
  detect_arch

  local api_url asset_url found
  TMPDIR_CREATED="$(mktemp -d)"

  api_url="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"
  curl -fsSL "${api_url}" -o "${TMPDIR_CREATED}/release.json"

  asset_url="$(
    jq -r --arg arch "${ARCH}" '
      .assets[]
      | select(
          (.name | ascii_downcase | contains("linux")) and
          (.name | ascii_downcase | contains($arch)) and
          (.name | (endswith(".tar.gz") or endswith(".tgz") or endswith(".zip")))
        )
      | .browser_download_url
    ' "${TMPDIR_CREATED}/release.json" | head -n1
  )"

  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    err "Could not find a matching llama-swap release asset for Linux ${ARCH}"
    exit 1
  fi

  log "Downloading ${asset_url}"
  curl -fL "${asset_url}" -o "${TMPDIR_CREATED}/llama-swap.pkg"

  case "${asset_url}" in
    *.tar.gz|*.tgz)
      tar -xzf "${TMPDIR_CREATED}/llama-swap.pkg" -C "${TMPDIR_CREATED}"
      ;;
    *.zip)
      unzip -q "${TMPDIR_CREATED}/llama-swap.pkg" -d "${TMPDIR_CREATED}"
      ;;
    *)
      err "Unsupported archive type for llama-swap asset"
      exit 1
      ;;
  esac

  found="$(find "${TMPDIR_CREATED}" -type f -name "llama-swap" | head -n1)"
  if [[ -z "${found}" ]]; then
    err "Could not find llama-swap binary after extraction"
    exit 1
  fi

  install -m 0755 "${found}" "${LLAMA_SWAP_BIN}"
  log "Installed llama-swap to ${LLAMA_SWAP_BIN}"
}

build_llama_cpp() {
  log "Installing llama.cpp (llama-server)..."

  local repo_dir="${SRC_DIR}/llama.cpp"
  if [[ ! -d "${repo_dir}/.git" ]]; then
    git clone https://github.com/ggml-org/llama.cpp "${repo_dir}"
  else
    git -C "${repo_dir}" pull --ff-only
  fi

  cmake -S "${repo_dir}" -B "${repo_dir}/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "${repo_dir}/build" --config Release -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

  local built=""
  if [[ -x "${repo_dir}/build/bin/llama-server" ]]; then
    built="${repo_dir}/build/bin/llama-server"
  elif [[ -x "${repo_dir}/build/bin/server" ]]; then
    built="${repo_dir}/build/bin/server"
  else
    built="$(find "${repo_dir}/build" -type f \( -name 'llama-server' -o -name 'server' \) | head -n1 || true)"
  fi

  if [[ -z "${built}" || ! -x "${built}" ]]; then
    err "Could not find built llama-server binary"
    exit 1
  fi

  install -m 0755 "${built}" "${LLAMA_SERVER_BIN}"
  log "Installed llama-server to ${LLAMA_SERVER_BIN}"
}

install_vllm_optional() {
  if [[ "${VLLM_ENABLED}" != "1" ]]; then
    log "Skipping vLLM install (VLLM_ENABLED=${VLLM_ENABLED})."
    return 0
  fi

  log "Installing optional vLLM into isolated venv..."
  mkdir -p "$(dirname "${VENV_DIR}")"

  if [[ ! -d "${VENV_DIR}" ]]; then
    python3 -m venv "${VENV_DIR}"
  fi

  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  python -m pip install --upgrade pip wheel setuptools build

  if ! python -m pip install --upgrade vllm; then
    warn "Direct pip install of vLLM failed."
    warn "For x86 CPU, vLLM often needs a source build. Leaving the venv in place for manual install."
  fi

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

# Backend selection:
#   llama_cpp (default) or vllm
export LLM_BACKEND="\${LLM_BACKEND:-llama_cpp}"

# Hugging Face access token for gated models like Gemma
# export HF_TOKEN="hf_xxx"

# Model source repos / quant selectors for llama.cpp --hf-repo
export QWEN15_REPO="\${QWEN15_REPO:-${DEFAULT_QWEN15_REPO}}"
export QWEN15_QUANT="\${QWEN15_QUANT:-${DEFAULT_QWEN15_QUANT}}"

export GEMMA1_REPO="\${GEMMA1_REPO:-${DEFAULT_GEMMA1_REPO}}"
# Leave empty to let llama.cpp use the repo default / first available file
export GEMMA1_QUANT="\${GEMMA1_QUANT:-${DEFAULT_GEMMA1_QUANT}}"

export QWEN3_REPO="\${QWEN3_REPO:-${DEFAULT_QWEN3_REPO}}"
export QWEN3_QUANT="\${QWEN3_QUANT:-${DEFAULT_QWEN3_QUANT}}"

# CPU-friendly context limits
export QWEN15_CTX="\${QWEN15_CTX:-8192}"
export GEMMA1_CTX="\${GEMMA1_CTX:-4096}"
export QWEN3_CTX="\${QWEN3_CTX:-12288}"

# llama.cpp tuning
export LLAMA_THREADS="\${LLAMA_THREADS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
export LLAMA_PARALLEL="\${LLAMA_PARALLEL:-1}"
export LLAMA_CONT_BATCHING="\${LLAMA_CONT_BATCHING:-1}"
export LLAMA_FLASH_ATTN="\${LLAMA_FLASH_ATTN:-0}"
export LLAMA_CTX_SHIFT="\${LLAMA_CTX_SHIFT:-1}"
export LLAMA_MLOCK="\${LLAMA_MLOCK:-0}"

# Optional per-model GPU layer offload if you ever repurpose this on a GPU host
export QWEN15_NGL="\${QWEN15_NGL:-0}"
export GEMMA1_NGL="\${GEMMA1_NGL:-0}"
export QWEN3_NGL="\${QWEN3_NGL:-0}"

# Optional vLLM tuning if LLM_BACKEND=vllm
export VLLM_USE_V1="\${VLLM_USE_V1:-1}"
export VLLM_CPU_KVCACHE_SPACE="\${VLLM_CPU_KVCACHE_SPACE:-8}"
# export VLLM_CPU_OMP_THREADS_BIND="0-7"

# Optional tcmalloc preload if installed separately
# export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4"
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
LOG_DIR="${STATE_DIR}/log"

ENV_FILE="${CFG_DIR}/env.sh"
PORTS_FILE="${RUNTIME_DIR}/ports.env"
LLAMA_SWAP_CFG="${RUNTIME_DIR}/llama-swap.yaml"

LLAMA_SWAP_BIN="${BIN_DIR}/llama-swap"
LLAMA_SERVER_BIN="${BIN_DIR}/llama-server"
VLLM_WRAPPER="${BIN_DIR}/vllm-local"

MODEL_QWEN15_ALIAS="qwen-coder-1.5b"
MODEL_GEMMA1_ALIAS="gemma3-1b"
MODEL_QWEN3_ALIAS="qwen-coder-3b"

mkdir -p "${RUNTIME_DIR}" "${LOG_DIR}" "${HOME}/.cache/huggingface"

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

if [[ "${LLM_BACKEND:-llama_cpp}" == "llama_cpp" ]]; then
  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "HF_TOKEN not set; Gemma may fail if access is gated for your account" >&2
  fi

  cat > "${LLAMA_SWAP_CFG}" <<YAML
healthCheckTimeout: 300
logLevel: info
logToStdout: proxy

models:
  ${MODEL_QWEN15_ALIAS}:
    cmd: |
      ${LLAMA_SERVER_BIN} \
        --host 127.0.0.1 \
        --port ${QWEN15_PORT} \
        --hf-repo ${QWEN15_REPO}${QWEN15_QUANT:+:${QWEN15_QUANT}} \
        --alias ${MODEL_QWEN15_ALIAS} \
        --ctx-size ${QWEN15_CTX:-8192} \
        --threads ${LLAMA_THREADS:-4} \
        --parallel ${LLAMA_PARALLEL:-1} \
        $( [[ "${LLAMA_CONT_BATCHING:-1}" == "1" ]] && printf '%s' '--cont-batching ' )\
        $( [[ "${LLAMA_CTX_SHIFT:-1}" == "1" ]] && printf '%s' '--ctx-shift ' )\
        $( [[ "${LLAMA_MLOCK:-0}" == "1" ]] && printf '%s' '--mlock ' )\
        $( [[ "${LLAMA_FLASH_ATTN:-0}" == "1" ]] && printf '%s' '--flash-attn ' )\
        --n-gpu-layers ${QWEN15_NGL:-0}
    proxy: http://127.0.0.1:${QWEN15_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_HOME
      - HF_TOKEN
      - LLAMA_THREADS
      - LLAMA_PARALLEL
      - LLAMA_CONT_BATCHING
      - LLAMA_FLASH_ATTN
      - LLAMA_CTX_SHIFT
      - LLAMA_MLOCK
      - QWEN15_CTX
      - QWEN15_NGL
      - QWEN15_REPO
      - QWEN15_QUANT

  ${MODEL_GEMMA1_ALIAS}:
    cmd: |
      ${LLAMA_SERVER_BIN} \
        --host 127.0.0.1 \
        --port ${GEMMA1_PORT} \
        --hf-repo ${GEMMA1_REPO}${GEMMA1_QUANT:+:${GEMMA1_QUANT}} \
        --alias ${MODEL_GEMMA1_ALIAS} \
        --ctx-size ${GEMMA1_CTX:-4096} \
        --threads ${LLAMA_THREADS:-4} \
        --parallel ${LLAMA_PARALLEL:-1} \
        $( [[ "${LLAMA_CONT_BATCHING:-1}" == "1" ]] && printf '%s' '--cont-batching ' )\
        $( [[ "${LLAMA_CTX_SHIFT:-1}" == "1" ]] && printf '%s' '--ctx-shift ' )\
        $( [[ "${LLAMA_MLOCK:-0}" == "1" ]] && printf '%s' '--mlock ' )\
        $( [[ "${LLAMA_FLASH_ATTN:-0}" == "1" ]] && printf '%s' '--flash-attn ' )\
        --n-gpu-layers ${GEMMA1_NGL:-0}
    proxy: http://127.0.0.1:${GEMMA1_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_HOME
      - HF_TOKEN
      - LLAMA_THREADS
      - LLAMA_PARALLEL
      - LLAMA_CONT_BATCHING
      - LLAMA_FLASH_ATTN
      - LLAMA_CTX_SHIFT
      - LLAMA_MLOCK
      - GEMMA1_CTX
      - GEMMA1_NGL
      - GEMMA1_REPO
      - GEMMA1_QUANT

  ${MODEL_QWEN3_ALIAS}:
    cmd: |
      ${LLAMA_SERVER_BIN} \
        --host 127.0.0.1 \
        --port ${QWEN3_PORT} \
        --hf-repo ${QWEN3_REPO}${QWEN3_QUANT:+:${QWEN3_QUANT}} \
        --alias ${MODEL_QWEN3_ALIAS} \
        --ctx-size ${QWEN3_CTX:-12288} \
        --threads ${LLAMA_THREADS:-4} \
        --parallel ${LLAMA_PARALLEL:-1} \
        $( [[ "${LLAMA_CONT_BATCHING:-1}" == "1" ]] && printf '%s' '--cont-batching ' )\
        $( [[ "${LLAMA_CTX_SHIFT:-1}" == "1" ]] && printf '%s' '--ctx-shift ' )\
        $( [[ "${LLAMA_MLOCK:-0}" == "1" ]] && printf '%s' '--mlock ' )\
        $( [[ "${LLAMA_FLASH_ATTN:-0}" == "1" ]] && printf '%s' '--flash-attn ' )\
        --n-gpu-layers ${QWEN3_NGL:-0}
    proxy: http://127.0.0.1:${QWEN3_PORT}
    checkEndpoint: /health
    ttl: 600
    env:
      - HF_HOME
      - HF_TOKEN
      - LLAMA_THREADS
      - LLAMA_PARALLEL
      - LLAMA_CONT_BATCHING
      - LLAMA_FLASH_ATTN
      - LLAMA_CTX_SHIFT
      - LLAMA_MLOCK
      - QWEN3_CTX
      - QWEN3_NGL
      - QWEN3_REPO
      - QWEN3_QUANT
YAML
else
  cat > "${LLAMA_SWAP_CFG}" <<YAML
healthCheckTimeout: 300
logLevel: info
logToStdout: proxy

models:
  ${MODEL_QWEN15_ALIAS}:
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
      ${VLLM_WRAPPER} serve ${QWEN15_REPO} \
        --host 127.0.0.1 \
        --port ${QWEN15_PORT} \
        --served-model-name ${MODEL_QWEN15_ALIAS} \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${QWEN15_CTX:-8192}

  ${MODEL_GEMMA1_ALIAS}:
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
      ${VLLM_WRAPPER} serve ${GEMMA1_REPO} \
        --host 127.0.0.1 \
        --port ${GEMMA1_PORT} \
        --served-model-name ${MODEL_GEMMA1_ALIAS} \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${GEMMA1_CTX:-4096}

  ${MODEL_QWEN3_ALIAS}:
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
      ${VLLM_WRAPPER} serve ${QWEN3_REPO} \
        --host 127.0.0.1 \
        --port ${QWEN3_PORT} \
        --served-model-name ${MODEL_QWEN3_ALIAS} \
        --dtype auto \
        --generation-config vllm \
        --max-model-len ${QWEN3_CTX:-12288}
YAML
fi

exec "${LLAMA_SWAP_BIN}" -listen "127.0.0.1:${LLAMA_SWAP_PORT}" -config "${LLAMA_SWAP_CFG}"
EOF
  chmod 0755 "${LAUNCHER_FILE}"
}

write_systemd_user_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Local LLM stack (llama-swap + local backends, CPU-first)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${LAUNCHER_FILE}
Restart=on-failure
RestartSec=3
TimeoutStopSec=60
WorkingDirectory=${BASE_DIR}

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
  llama-swap:    ${LLAMA_SWAP_BIN}
  llama-server:  ${LLAMA_SERVER_BIN}
  vLLM wrapper:  ${VLLM_WRAPPER} (only useful if VLLM_ENABLED=1 and vLLM was installed)

Config:
  ${ENV_FILE}

Service:
  ${SERVICE_FILE}

Runtime state:
  ${RUNTIME_DIR}

Recommended next steps:
  1) Review ${ENV_FILE}
  2) Add HF_TOKEN there if you want Gemma
  3) Enable the service:
     systemctl --user daemon-reload
     systemctl --user enable --now local-llm-stack

Check status:
  systemctl --user status local-llm-stack
  journalctl --user -u local-llm-stack -f

Optional persistence after logout:
  loginctl enable-linger "${USER}"

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

Notes:
  - Default backend is llama.cpp via llama-server and GGUF models pulled natively from Hugging Face with --hf-repo.
  - Gemma needs HF_TOKEN and accepted access terms on Hugging Face.
  - llama.cpp downloads are cached in the Hugging Face cache when using --hf-repo.
  - vLLM remains optional and isolated in its own venv.
EOF
}

main() {
  detect_distro
  setup_pkg_manager
  install_system_packages
  ensure_dirs
  preflight_checks
  install_llama_swap
  build_llama_cpp
  install_vllm_optional
  write_env_file
  write_launcher
  write_systemd_user_service

  systemctl --user daemon-reload || true

  print_notes

  if [[ -z "${HF_TOKEN:-}" ]]; then
    warn "HF_TOKEN is not set in this shell. Qwen can still work; Gemma will not download until HF_TOKEN is added to ${ENV_FILE}."
  fi

  warn "This script now defaults to llama.cpp. vLLM is optional and isolated to ${VENV_DIR} if enabled."
}

main "$@"
