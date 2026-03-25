# Fedora test notes

Recommended test flow on Fedora Workstation:

```bash
sudo dnf update -y
sudo dnf install -y git
unzip nvim-setup-production-repo.zip
cd nvim-setup-production-repo
chmod +x setup-nvim.sh
./setup-nvim.sh
```

Then reload shell and start Neovim:

```bash
source ~/.bashrc
n
```

If the AI backend is not running yet, the editor should still work normally. Only Avante requests will fail when invoked.
