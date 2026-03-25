# Neovim Development Environment Setup Script

This repository bootstraps a modern, production-ready Neovim development environment with:

- LSP + autocomplete
- file explorer sidebar
- fuzzy search
- formatting
- statusline with git info
- AI integration via OpenAI-compatible APIs
- safe backup system for all modified files

## Overview

The script is designed to:

- run as a normal user, not root
- use `sudo` only for package installation
- avoid breaking existing setups by creating backups
- remain LLM backend agnostic via OpenAI-compatible APIs

## What this script installs and configures

### System packages

Depending on distro and what is already installed:

- `neovim`
- `git`
- `curl`
- `ripgrep`
- `fd` / `fd-find`
- `make`
- `gcc` / build tools
- `nodejs`
- `npm`
- `python3`
- `pip3`

### Neovim setup

The script generates a full Neovim config using:

- `lazy.nvim` as plugin manager
- `nvim-tree` as file explorer
- `telescope` for search/fuzzy finding
- `lualine` for statusline
- `treesitter` for syntax highlighting
- `mason.nvim` and `nvim-lspconfig` for LSP
- `nvim-cmp` for completion
- `conform.nvim` for formatting
- `avante.nvim` for AI integration

## Features

### File explorer

- `Ctrl+n` toggles the file tree
- `Enter`, `o`, `t` open a file in a new tab
- `v` opens vertical split
- `s` opens horizontal split

### Search

- `Ctrl+f` searches across project
- `<leader>ff` finds files
- `<leader>fg` greps text
- `<leader>fb` shows buffers
- `<leader>fh` shows help tags

### Pane navigation

- `Ctrl+Left`
- `Ctrl+Right`
- `Ctrl+Up`
- `Ctrl+Down`

Fallback:

- `Ctrl+h`
- `Ctrl+j`
- `Ctrl+k`
- `Ctrl+l`

### Tabs

- `<leader>tn` new tab
- `<leader>tl` next tab
- `<leader>th` previous tab
- `<leader>tq` close tab

### LSP

Configured servers:

- Go: `gopls`
- Python: `pyright`
- TypeScript: `ts_ls`
- Lua: `lua_ls`
- Bash: `bashls`
- JSON: `jsonls`
- YAML: `yamlls`

Keybindings:

- `gd` go to definition
- `gr` references
- `K` hover
- `<leader>rn` rename
- `<leader>ca` code actions

### Formatting

- `<leader>fm` formats the buffer

Formatters:

- Lua: `stylua`
- Python: `black`
- JavaScript / TypeScript / JSON / YAML / Markdown: `prettier`
- Go: `gofmt`

## AI integration

The setup uses `avante.nvim` with an OpenAI-compatible API.

### Supported backends

Examples:

- vLLM
- Ollama in OpenAI-compatible mode
- llama-swap
- LibreChat
- custom LLM gateway

### Keybindings

#### Ask

- `<leader>la`
- `<leader>llm`

Use this for one-shot prompts like refactor, explain, fix, or generate.

#### Chat

- `<leader>lc`
- `<leader>chat`

Use this for persistent conversation and planning.

### Ask vs Chat

- Ask: fast coding task or current selection
- Chat: longer reasoning, design, debugging discussion

### Code modification behavior

Avante can modify code, but changes are typically surfaced as diffs rather than blindly auto-applied.

## Environment variables

The script appends:

```bash
export NVIM_LLM_ENDPOINT="http://127.0.0.1:8000/v1"
export NVIM_LLM_API_KEY="dummy"
export NVIM_LLM_MODEL="Qwen/Qwen2.5-Coder-7B-Instruct"
export NVIM_LLM_TEMPERATURE="0.1"
export NVIM_LLM_MAX_TOKENS="2048"
```

### Example backends

#### vLLM

```bash
export NVIM_LLM_ENDPOINT="http://127.0.0.1:8000/v1"
export NVIM_LLM_MODEL="Qwen/Qwen2.5-Coder-7B-Instruct"
```

#### Ollama

```bash
export NVIM_LLM_ENDPOINT="http://127.0.0.1:11434/v1"
export NVIM_LLM_MODEL="qwen2.5-coder:7b"
```

#### llama-swap or custom gateway

```bash
export NVIM_LLM_ENDPOINT="http://127.0.0.1:8080/v1"
export NVIM_LLM_MODEL="coder-small"
```

## Files modified

The script may modify:

- `~/.bashrc`
- `~/.zshrc`
- `~/.config/nvim/init.lua`

## Backup system

Before modifying anything, the script creates timestamped backups.

Location:

```bash
~/.setup-nvim-backups/<timestamp>
```

Example:

```bash
~/.setup-nvim-backups/20260325-153045
```

What gets backed up:

- `.bashrc`
- `.zshrc`
- entire `~/.config/nvim/` directory

## What requires root

You do not run the script as root.

The script uses `sudo` only for installing system packages.

## What still needs manual setup

### Nerd Font

Recommended for icons in file tree and statusline.

### LLM backend

The script does not install:

- vLLM
- Ollama
- llama-swap
- LibreChat

You need one of those separately if you want AI features.

### Package managers

If `npm`, `pip3`, or `go` are unavailable, some language tools may not install automatically.

## Usage

```bash
chmod +x setup-nvim.sh
./setup-nvim.sh
```

Reload shell:

```bash
source ~/.bashrc
```

Then start Neovim:

```bash
n
```

## Distro support

- Ubuntu / Debian
- Fedora
- Rocky / RHEL / Alma / CentOS
- Arch / Manjaro / EndeavourOS
- openSUSE / SLES

## Notes

### Ctrl+Arrow not working

Some terminals do not pass those keys correctly. Use:

- `Ctrl+h`
- `Ctrl+j`
- `Ctrl+k`
- `Ctrl+l`

### Existing Neovim config

Your old config is backed up in:

```bash
~/.setup-nvim-backups/<timestamp>
```

## Summary

This setup gives you:

- modern Neovim IDE workflow
- file explorer
- fuzzy search
- Treesitter
- LSP + autocomplete
- formatting
- AI coding assistant
- backend-agnostic LLM integration
- safe backups

## Philosophy

- no lock-in
- safe by default
- keyboard-first workflow
- easy to extend for better local or remote LLM backends later
