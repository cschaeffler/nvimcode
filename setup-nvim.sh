#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Neovim bootstrap for development environments
#
# Features:
# - Detect distro and install required packages
# - Install Neovim if missing
# - Install lazy.nvim
# - Configure:
#   * nvim-tree file explorer
#   * telescope search
#   * lualine status bar
#   * treesitter
#   * LSP + completion
#   * formatting
#   * Avante with OpenAI-compatible API endpoint
# - Add aliases:
#   * n -> nvim
#   * vim -> nvim
# - Bindings:
#   * Ctrl+n       toggle file tree
#   * Ctrl+f       live grep
#   * Ctrl+Left    focus left pane
#   * Ctrl+Right   focus right pane
#   * Ctrl+Up      focus upper pane
#   * Ctrl+Down    focus lower pane
# - AI bindings:
#   * <leader>la    Ask
#   * <leader>llm   Ask
#   * <leader>lc    Chat
#   * <leader>chat  Chat
# - Open files from file tree in a NEW TAB by default
# - Backup every existing file or directory it modifies
#
# Run as normal user, not root.
# ============================================================

log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/.setup-nvim-backups/${TIMESTAMP}"

backup_file_once() {
  local file="$1"
  [ -e "$file" ] || return 0

  mkdir -p "${BACKUP_DIR}"
  local target="${BACKUP_DIR}${file#$HOME}"
  mkdir -p "$(dirname "$target")"

  if [ ! -e "$target" ]; then
    cp -a "$file" "$target"
    log "Backed up file: $file -> $target"
  fi
}

backup_dir_once() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  mkdir -p "${BACKUP_DIR}"
  local target="${BACKUP_DIR}${dir#$HOME}"
  mkdir -p "$(dirname "$target")"

  if [ ! -e "$target" ]; then
    cp -a "$dir" "$target"
    log "Backed up directory: $dir -> $target"
  fi
}

append_line_if_missing() {
  local file="$1"
  local line="$2"

  if [ -e "$file" ]; then
    backup_file_once "$file"
  fi

  touch "$file"

  if ! grep -Fqx "$line" "$file"; then
    printf "\n%s\n" "$line" >> "$file"
    log "Added to ${file}: ${line}"
  fi
}

detect_distro() {
  if [ ! -f /etc/os-release ]; then
    err "/etc/os-release not found, cannot detect distro"
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
      if require_cmd dnf; then
        PKG_MODE="dnf"
      elif require_cmd yum; then
        PKG_MODE="yum"
      else
        err "No supported package manager found for RHEL-like distro"
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
        *debian*)
          PKG_MODE="apt"
          ;;
        *rhel*|*fedora*)
          if require_cmd dnf; then
            PKG_MODE="dnf"
          elif require_cmd yum; then
            PKG_MODE="yum"
          else
            err "No supported package manager found for RHEL-like distro"
            exit 1
          fi
          ;;
        *arch*)
          PKG_MODE="pacman"
          ;;
        *suse*)
          PKG_MODE="zypper"
          ;;
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
  [ "${#pkgs[@]}" -eq 0 ] && return 0

  if ! require_cmd sudo; then
    err "sudo is required to install packages"
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
      err "Unknown package manager mode: ${PKG_MODE}"
      exit 1
      ;;
  esac
}

ensure_local_bin() {
  mkdir -p "${HOME}/.local/bin"

  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *)
      warn "~/.local/bin is not in PATH for this shell."
      warn 'Add this to your shell rc if needed: export PATH="$HOME/.local/bin:$PATH"'
      ;;
  esac
}

install_system_packages() {
  local pkgs=()

  case "${PKG_MODE}" in
    apt)
      require_cmd nvim    || pkgs+=(neovim)
      require_cmd git     || pkgs+=(git)
      require_cmd curl    || pkgs+=(curl)
      require_cmd rg      || pkgs+=(ripgrep)
      require_cmd fd || require_cmd fdfind || pkgs+=(fd-find)
      require_cmd make    || pkgs+=(make)
      require_cmd gcc     || pkgs+=(build-essential)
      require_cmd node    || pkgs+=(nodejs npm)
      require_cmd python3 || pkgs+=(python3 python3-pip python3-venv)
      ;;
    dnf|yum)
      require_cmd nvim    || pkgs+=(neovim)
      require_cmd git     || pkgs+=(git)
      require_cmd curl    || pkgs+=(curl)
      require_cmd rg      || pkgs+=(ripgrep)
      require_cmd fd      || pkgs+=(fd-find)
      require_cmd make    || pkgs+=(make)
      require_cmd gcc     || pkgs+=(gcc gcc-c++)
      require_cmd node    || pkgs+=(nodejs npm)
      require_cmd python3 || pkgs+=(python3 python3-pip)
      ;;
    pacman)
      require_cmd nvim    || pkgs+=(neovim)
      require_cmd git     || pkgs+=(git)
      require_cmd curl    || pkgs+=(curl)
      require_cmd rg      || pkgs+=(ripgrep)
      require_cmd fd      || pkgs+=(fd)
      require_cmd make || require_cmd gcc || pkgs+=(base-devel)
      require_cmd node    || pkgs+=(nodejs npm)
      require_cmd python3 || pkgs+=(python python-pip)
      ;;
    zypper)
      require_cmd nvim    || pkgs+=(neovim)
      require_cmd git     || pkgs+=(git)
      require_cmd curl    || pkgs+=(curl)
      require_cmd rg      || pkgs+=(ripgrep)
      require_cmd fd      || pkgs+=(fd)
      require_cmd make    || pkgs+=(make)
      require_cmd gcc     || pkgs+=(gcc gcc-c++)
      require_cmd node    || pkgs+=(nodejs npm)
      require_cmd python3 || pkgs+=(python3 python3-pip)
      ;;
  esac

  if [ "${#pkgs[@]}" -gt 0 ]; then
    log "Installing packages: ${pkgs[*]}"
    pkg_install "${pkgs[@]}"
  else
    log "Required system packages already installed."
  fi

  if ! require_cmd fd && require_cmd fdfind; then
    mkdir -p "${HOME}/.local/bin"
    ln -sf "$(command -v fdfind)" "${HOME}/.local/bin/fd"
    log "Created ~/.local/bin/fd -> fdfind"
  fi
}

install_lazy_nvim() {
  local lazy_dir="${HOME}/.local/share/nvim/lazy/lazy.nvim"
  if [ ! -d "${lazy_dir}" ]; then
    log "Installing lazy.nvim..."
    git clone --filter=blob:none https://github.com/folke/lazy.nvim.git --branch=stable "${lazy_dir}"
  else
    log "lazy.nvim already installed."
  fi
}

setup_aliases() {
  log "Configuring aliases for n and vim to use nvim..."

  append_line_if_missing "${HOME}/.bashrc" "alias n='nvim'"
  append_line_if_missing "${HOME}/.bashrc" "alias vim='nvim'"

  if [ -f "${HOME}/.zshrc" ] || [ "${SHELL##*/}" = "zsh" ]; then
    append_line_if_missing "${HOME}/.zshrc" "alias n='nvim'"
    append_line_if_missing "${HOME}/.zshrc" "alias vim='nvim'"
  fi
}

setup_llm_env() {
  log "Configuring environment variables for OpenAI-compatible LLM endpoint..."

  append_line_if_missing "${HOME}/.bashrc" 'export NVIM_LLM_ENDPOINT="http://127.0.0.1:8000/v1"'
  append_line_if_missing "${HOME}/.bashrc" 'export NVIM_LLM_API_KEY="dummy"'
  append_line_if_missing "${HOME}/.bashrc" 'export NVIM_LLM_MODEL="Qwen/Qwen2.5-Coder-7B-Instruct"'
  append_line_if_missing "${HOME}/.bashrc" 'export NVIM_LLM_TEMPERATURE="0.1"'
  append_line_if_missing "${HOME}/.bashrc" 'export NVIM_LLM_MAX_TOKENS="2048"'

  if [ -f "${HOME}/.zshrc" ] || [ "${SHELL##*/}" = "zsh" ]; then
    append_line_if_missing "${HOME}/.zshrc" 'export NVIM_LLM_ENDPOINT="http://127.0.0.1:8000/v1"'
    append_line_if_missing "${HOME}/.zshrc" 'export NVIM_LLM_API_KEY="dummy"'
    append_line_if_missing "${HOME}/.zshrc" 'export NVIM_LLM_MODEL="Qwen/Qwen2.5-Coder-7B-Instruct"'
    append_line_if_missing "${HOME}/.zshrc" 'export NVIM_LLM_TEMPERATURE="0.1"'
    append_line_if_missing "${HOME}/.zshrc" 'export NVIM_LLM_MAX_TOKENS="2048"'
  fi
}

write_nvim_config() {
  local config_dir="${HOME}/.config/nvim"
  local init_file="${config_dir}/init.lua"

  if [ -d "${config_dir}" ]; then
    backup_dir_once "${config_dir}"
  fi

  if [ -f "${init_file}" ]; then
    backup_file_once "${init_file}"
  fi

  mkdir -p "${config_dir}"

  cat > "${init_file}" <<'EOF'
-- ==========================================================
-- Base options
-- ==========================================================
vim.g.mapleader = " "

vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.opt.termguicolors = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.updatetime = 250
vim.opt.signcolumn = "yes"
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.cursorline = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.smartindent = true

-- ==========================================================
-- lazy.nvim bootstrap
-- ==========================================================
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
vim.opt.rtp:prepend(lazypath)

-- ==========================================================
-- Early keymaps
-- ==========================================================
local map = vim.keymap.set
local opts = { noremap = true, silent = true }

map("n", "<C-Left>",  "<C-w>h", opts)
map("n", "<C-Right>", "<C-w>l", opts)
map("n", "<C-Up>",    "<C-w>k", opts)
map("n", "<C-Down>",  "<C-w>j", opts)

map("n", "<C-h>", "<C-w>h", opts)
map("n", "<C-l>", "<C-w>l", opts)
map("n", "<C-k>", "<C-w>k", opts)
map("n", "<C-j>", "<C-w>j", opts)

map("n", "<leader>tn", "<cmd>tabnew<CR>", opts)
map("n", "<leader>tl", "<cmd>tabnext<CR>", opts)
map("n", "<leader>th", "<cmd>tabprevious<CR>", opts)
map("n", "<leader>tq", "<cmd>tabclose<CR>", opts)

require("lazy").setup({
  { "nvim-lua/plenary.nvim" },

  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },

  {
    "nvim-tree/nvim-tree.lua",
    version = "*",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local api = require("nvim-tree.api")

      local function tree_on_attach(bufnr)
        local function bmap(lhs, rhs, desc)
          vim.keymap.set("n", lhs, rhs, {
            desc = "nvim-tree: " .. desc,
            buffer = bufnr,
            noremap = true,
            silent = true,
            nowait = true,
          })
        end

        api.config.mappings.default_on_attach(bufnr)

        bmap("<CR>", api.node.open.tab, "Open: New Tab")
        bmap("o",    api.node.open.tab, "Open: New Tab")
        bmap("t",    api.node.open.tab, "Open: New Tab")

        bmap("v", api.node.open.vertical,   "Open: Vertical Split")
        bmap("s", api.node.open.horizontal, "Open: Horizontal Split")

        bmap("<C-Left>",  "<C-w>h", "Focus Left")
        bmap("<C-Right>", "<C-w>l", "Focus Right")
        bmap("<C-Up>",    "<C-w>k", "Focus Up")
        bmap("<C-Down>",  "<C-w>j", "Focus Down")
      end

      require("nvim-tree").setup({
        on_attach = tree_on_attach,
        hijack_cursor = true,
        sync_root_with_cwd = true,
        respect_buf_cwd = true,
        update_focused_file = {
          enable = true,
          update_root = false,
        },
        renderer = {
          group_empty = true,
          highlight_git = true,
          icons = {
            show = {
              file = true,
              folder = true,
              folder_arrow = true,
              git = true,
            },
          },
        },
        view = {
          width = 34,
          preserve_window_proportions = true,
        },
        filters = {
          dotfiles = false,
        },
      })
    end,
  },

  {
    "nvim-telescope/telescope.nvim",
    branch = "0.1.x",
    dependencies = {
      "nvim-lua/plenary.nvim",
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          layout_config = {
            horizontal = { preview_width = 0.55 },
          },
        },
        pickers = {
          find_files = {
            hidden = true,
          },
        },
      })
      pcall(telescope.load_extension, "fzf")
    end,
  },

  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("lualine").setup({
        options = {
          theme = "auto",
          globalstatus = true,
          section_separators = "",
          component_separators = "|",
        },
      })
    end,
  },

  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = {
          "bash",
          "lua",
          "vim",
          "vimdoc",
          "json",
          "yaml",
          "markdown",
          "python",
          "javascript",
          "typescript",
          "tsx",
          "go",
        },
        auto_install = true,
        highlight = { enable = true },
        indent = { enable = true },
      })
    end,
  },

  { "williamboman/mason.nvim", config = true },
  { "williamboman/mason-lspconfig.nvim", config = true },
  { "neovim/nvim-lspconfig" },

  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",
      "hrsh7th/cmp-buffer",
      "hrsh7th/cmp-path",
      "L3MON4D3/LuaSnip",
    },
    config = function()
      local cmp = require("cmp")
      cmp.setup({
        snippet = {
          expand = function(args)
            require("luasnip").lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-Space>"] = cmp.mapping.complete(),
          ["<CR>"]      = cmp.mapping.confirm({ select = true }),
          ["<Tab>"]     = cmp.mapping.select_next_item(),
          ["<S-Tab>"]   = cmp.mapping.select_prev_item(),
        }),
        sources = cmp.config.sources({
          { name = "nvim_lsp" },
          { name = "path" },
          { name = "buffer" },
        }),
      })
    end,
  },

  {
    "stevearc/conform.nvim",
    config = function()
      require("conform").setup({
        formatters_by_ft = {
          lua = { "stylua" },
          python = { "black" },
          javascript = { "prettier" },
          typescript = { "prettier" },
          javascriptreact = { "prettier" },
          typescriptreact = { "prettier" },
          json = { "prettier" },
          yaml = { "prettier" },
          markdown = { "prettier" },
          go = { "gofmt" },
        },
      })

      vim.keymap.set("n", "<leader>fm", function()
        require("conform").format({ async = true, lsp_fallback = true })
      end, { desc = "Format buffer" })
    end,
  },

  {
    "yetone/avante.nvim",
    event = "VeryLazy",
    version = false,
    build = "make",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "MunifTanjim/nui.nvim",
      "nvim-tree/nvim-web-devicons",
      "stevearc/dressing.nvim",
      "hrsh7th/nvim-cmp",
      "nvim-telescope/telescope.nvim",
    },
    opts = function()
      local endpoint = vim.env.NVIM_LLM_ENDPOINT or "http://127.0.0.1:8000/v1"
      local model = vim.env.NVIM_LLM_MODEL or "Qwen/Qwen2.5-Coder-7B-Instruct"
      local temperature = tonumber(vim.env.NVIM_LLM_TEMPERATURE or "0.1")
      local max_tokens = tonumber(vim.env.NVIM_LLM_MAX_TOKENS or "2048")

      return {
        provider = "local_openai",
        auto_suggestions_provider = "local_openai",

        providers = {
          local_openai = {
            __inherited_from = "openai",
            endpoint = endpoint,
            api_key_name = "NVIM_LLM_API_KEY",
            model = model,
            timeout = 30000,
            extra_request_body = {
              temperature = temperature,
              max_tokens = max_tokens,
            },
          },
        },

        input = {
          provider = "dressing",
        },
        selector = {
          provider = "telescope",
        },
      }
    end,
  },
})

local builtin = require("telescope.builtin")

map("n", "<C-f>", builtin.live_grep, { desc = "Live grep in project" })
map("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
map("n", "<leader>fg", builtin.live_grep, { desc = "Grep text" })
map("n", "<leader>fb", builtin.buffers, { desc = "Buffers" })
map("n", "<leader>fh", builtin.help_tags, { desc = "Help tags" })

map("n", "<C-n>", "<cmd>NvimTreeToggle<CR>", opts)
map("n", "<leader>e", "<cmd>NvimTreeFocus<CR>", opts)
map("n", "<Esc>", "<cmd>nohlsearch<CR>", opts)

-- AI keybindings
map("n", "<leader>la",   "<cmd>AvanteAsk<CR>",  { noremap = true, silent = true, desc = "LLM Ask" })
map("v", "<leader>la",   ":AvanteAsk<CR>",      { noremap = true, silent = true, desc = "LLM Ask (selection)" })

map("n", "<leader>llm",  "<cmd>AvanteAsk<CR>",  { noremap = true, silent = true, desc = "LLM Ask" })
map("v", "<leader>llm",  ":AvanteAsk<CR>",      { noremap = true, silent = true, desc = "LLM Ask (selection)" })

map("n", "<leader>lc",   "<cmd>AvanteChat<CR>", { noremap = true, silent = true, desc = "LLM Chat" })
map("v", "<leader>lc",   ":AvanteChat<CR>",     { noremap = true, silent = true, desc = "LLM Chat (selection)" })

map("n", "<leader>chat", "<cmd>AvanteChat<CR>", { noremap = true, silent = true, desc = "LLM Chat" })
map("v", "<leader>chat", ":AvanteChat<CR>",     { noremap = true, silent = true, desc = "LLM Chat (selection)" })

local capabilities = require("cmp_nvim_lsp").default_capabilities()
local lspconfig = require("lspconfig")

local servers = {
  "gopls",
  "pyright",
  "ts_ls",
  "lua_ls",
  "bashls",
  "jsonls",
  "yamlls",
}

for _, server in ipairs(servers) do
  lspconfig[server].setup({
    capabilities = capabilities,
  })
end

vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })
vim.keymap.set("n", "gr", vim.lsp.buf.references, { desc = "References" })
vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Hover" })
vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, { desc = "Rename" })
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
EOF

  log "Wrote Neovim config to ${init_file}"
}

install_common_language_tools() {
  log "Installing common formatter and language tools where possible..."

  if require_cmd npm; then
    npm install -g \
      prettier \
      pyright \
      bash-language-server \
      typescript \
      typescript-language-server || true
  else
    warn "npm not found, skipping npm-based language tools"
  fi

  if require_cmd pip3; then
    pip3 install --user black || true
  else
    warn "pip3 not found, skipping black install"
  fi

  if require_cmd go; then
    go install golang.org/x/tools/gopls@latest || true
  else
    warn "go not found, skipping gopls install"
  fi
}

run_headless_sync() {
  log "Installing Neovim plugins..."
  nvim --headless "+Lazy! sync" +qa || true
}

post_install_notes() {
  cat <<EOF

============================================================
Done.

Backups:
  ${BACKUP_DIR}

Reload shell:
  source ~/.bashrc
  # or
  source ~/.zshrc

Aliases:
  n   -> nvim
  vim -> nvim

Main keybindings:
  Ctrl+n        Toggle file tree
  Ctrl+f        Search in project
  Ctrl+Left     Focus left pane
  Ctrl+Right    Focus right pane
  Ctrl+Up       Focus upper pane
  Ctrl+Down     Focus lower pane

File tree behavior:
  Enter / o / t on a file -> open in NEW TAB
  v -> open in vertical split
  s -> open in horizontal split

Useful Neovim keys:
  <leader>ff    Find files
  <leader>fg    Grep text
  <leader>fb    Buffers
  <leader>fh    Help tags
  <leader>fm    Format buffer
  gd            Go to definition
  gr            References
  K             Hover
  <leader>rn    Rename
  <leader>ca    Code action

AI / Avante:
  <leader>la    Ask
  <leader>llm   Ask
  <leader>lc    Chat
  <leader>chat  Chat

Open Neovim:
  n
  # or
  nvim

If Ctrl+Arrow does not work in your terminal, use:
  Ctrl+h / Ctrl+j / Ctrl+k / Ctrl+l

============================================================

EOF
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    err "Please run this script as your normal user, not root"
    exit 1
  fi

  detect_distro
  setup_pkg_manager
  ensure_local_bin
  install_system_packages
  install_lazy_nvim
  setup_aliases
  setup_llm_env
  write_nvim_config
  install_common_language_tools
  run_headless_sync
  post_install_notes
}

main "$@"
