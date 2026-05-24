#!/data/data/com.termux/files/usr/bin/bash
# PSG1 cyberdeck — complete Termux setup
# Idempotent: safe to run multiple times.
# Run inside Termux:  bash /sdcard/psg1_termux_setup.sh
#
# IMPORTANT — before you run this, edit AUTHORIZED_PUBKEY below to be the
# `~/.ssh/id_*.pub` content of whatever machine you want to SSH FROM into
# the PSG1. The example value is a placeholder.

set -euo pipefail

# REPLACE THIS with your own ssh public key — `cat ~/.ssh/id_ed25519.pub` on
# whatever client machine you want to log in from. Multiple keys can be added
# after first run by editing ~/.ssh/authorized_keys directly.
AUTHORIZED_PUBKEY="ssh-ed25519 AAAA<REPLACE_WITH_YOUR_PUBKEY> you@your-machine"

SSH_PORT="8022"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

log "PSG1 cyberdeck Termux setup starting"

# --- 1. Storage permission so Termux can see /sdcard ---
if [ ! -d "$HOME/storage" ]; then
  log "Requesting storage permission (tap Allow on the dialog if it pops)"
  termux-setup-storage
  sleep 2
fi

# --- 2. Update + install base packages ---
log "Updating package lists"
yes | pkg update -y || true
yes | pkg upgrade -y || true

log "Installing base CLI packages"
pkg install -y \
  python nodejs-lts git gh openssh rsync curl wget \
  nano vim neovim tmux htop ripgrep fd fzf jq tree \
  unzip zip tar file which ncurses-utils termux-api \
  proot-distro man less bat eza zoxide starship

# --- 3. OpenSSH server config ---
log "Configuring sshd on port $SSH_PORT"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# authorized_keys — add configured key without duplicating
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if [[ "$AUTHORIZED_PUBKEY" == *REPLACE_WITH_YOUR_PUBKEY* ]]; then
  log "WARNING: AUTHORIZED_PUBKEY is still the placeholder — skipping authorized_keys update"
  log "         Edit this script and re-run, or append your key manually:"
  log "         echo 'your ssh-ed25519 ...' >> ~/.ssh/authorized_keys"
elif ! grep -qF "$AUTHORIZED_PUBKEY" "$HOME/.ssh/authorized_keys"; then
  echo "$AUTHORIZED_PUBKEY" >> "$HOME/.ssh/authorized_keys"
  log "Added pubkey to authorized_keys"
else
  log "Pubkey already present"
fi

# Termux sshd listens on 8022 by default; confirm
SSHD_CFG="$PREFIX/etc/ssh/sshd_config"
if ! grep -q "^Port $SSH_PORT" "$SSHD_CFG"; then
  echo "Port $SSH_PORT" >> "$SSHD_CFG"
fi
# Disable password auth — keys only
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CFG" || \
  echo "PasswordAuthentication no" >> "$SSHD_CFG"

# Start sshd now if not running
if ! pgrep -x sshd >/dev/null 2>&1; then
  sshd
  log "sshd started"
else
  log "sshd already running"
fi

# --- 4. Termux:Boot autostart — sshd survives reboot ---
log "Setting up termux-boot autostart"
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"

cat > "$BOOT_DIR/00-wakelock" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
EOF
chmod +x "$BOOT_DIR/00-wakelock"

cat > "$BOOT_DIR/10-sshd" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
sshd
EOF
chmod +x "$BOOT_DIR/10-sshd"

# --- 5. Bashrc — sane defaults for a cyberdeck shell ---
log "Writing ~/.bashrc"
cat > "$HOME/.bashrc" <<'EOF'
# PSG1 cyberdeck bashrc
export EDITOR=nvim
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
# Keep Claude Code on the Termux-safe pure-JS build — stop the in-app updater
# from silently pulling a glibc-native build that won't run on bionic (see §9).
export DISABLE_AUTOUPDATER=1

# History
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend cmdhist

# Aliases
alias ll='eza -la --git --icons'
alias l='eza -l --icons'
alias ls='eza --icons'
alias tree='eza --tree --icons'
alias cat='bat --paging=never'
alias grep='grep --color=auto'
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias ip-wlan='ip -4 addr show wlan0 | grep inet'
alias myip='curl -s https://ifconfig.me; echo'

# Pretty prompt
eval "$(starship init bash 2>/dev/null)" || PS1='\[\e[1;32m\]psg1\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# zoxide
eval "$(zoxide init bash 2>/dev/null)" || true

# fzf keybindings
[ -f "$PREFIX/share/fzf/key-bindings.bash" ] && source "$PREFIX/share/fzf/key-bindings.bash"

# Ensure sshd is up when a Termux session opens — post-reboot recovery, since
# Termux:Boot (10-sshd) is skipped when the firmware disables the package during
# the boot window. The jumpbox keepalive cold-starts Termux to trigger this.
# No-op if sshd is already running.
command -v sshd >/dev/null && ! pgrep -x sshd >/dev/null 2>&1 && sshd 2>/dev/null

# Welcome message
if [ -z "${PSG1_WELCOMED:-}" ]; then
  export PSG1_WELCOMED=1
  echo
  echo "  ╭─ PSG1 cyberdeck ───────────────────────────"
  echo "  │ host:  $(hostname)"
  echo "  │ wlan:  $(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}')"
  echo "  │ ssh:   port 8022"
  echo "  ╰────────────────────────────────────────────"
  echo
fi
EOF

# --- 6. Starship config ---
log "Writing starship config"
mkdir -p "$HOME/.config"
cat > "$HOME/.config/starship.toml" <<'EOF'
add_newline = false
format = """$username$hostname$directory$git_branch$git_status$cmd_duration
$character"""

[username]
show_always = false

[hostname]
ssh_only = true
format = "[@$hostname](bold red) "

[directory]
truncation_length = 3
truncate_to_repo = true

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"

[cmd_duration]
min_time = 2000
format = "[$duration](bold yellow) "
EOF

# --- 7. nvim quick-start config ---
log "Seeding minimal nvim config"
mkdir -p "$HOME/.config/nvim"
if [ ! -f "$HOME/.config/nvim/init.lua" ]; then
  cat > "$HOME/.config/nvim/init.lua" <<'EOF'
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.smartindent = true
vim.opt.termguicolors = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.scrolloff = 6
vim.opt.mouse = "a"
vim.opt.undofile = true
vim.g.mapleader = " "

vim.keymap.set("n", "<leader>w", ":w<CR>")
vim.keymap.set("n", "<leader>q", ":q<CR>")
vim.keymap.set("n", "<leader>e", ":Lex 20<CR>")
EOF
fi

# --- 8. Solana CLI attempt ---
# NOTE: Anza does NOT publish aarch64-unknown-linux-gnu binaries, so the
# installer 404s on Termux/Linux ARM. Falls through to a cargo install attempt
# which is likely to fail too. See PSG1_CYBERDECK_OPS.md for the JS SDK path
# (use @solana/kit + node instead).
log "Installing Solana CLI (likely to fail on aarch64-linux — see notes for JS SDK alternative)"
if ! command -v solana >/dev/null 2>&1; then
  pkg install -y rust
  curl -sSfL https://release.anza.xyz/stable/install -o "$PREFIX/tmp/solana-install.sh" || true
  if [ -f "$PREFIX/tmp/solana-install.sh" ]; then
    sh "$PREFIX/tmp/solana-install.sh" 2>/dev/null || log "Solana installer failed (expected on aarch64-linux)"
  fi
fi

# --- 9. Claude Code CLI ---
# Claude Code v2.1.113+ ships a glibc-native binary that will NOT run on Termux
# (Android/bionic libc): `claude` dies with "native binary not installed".
# 2.1.112 is the last pure-JS release and runs fine here, so we pin to it. The
# in-app auto-updater is disabled in ~/.bashrc (§5) so it can't silently pull a
# broken native build. To run a CURRENT Claude Code instead, install it inside
# the Ubuntu chroot (glibc) — see PSG1_CYBERDECK_OPS.md → "Claude Code CLI".
CLAUDE_PIN="2.1.112"
log "Installing Claude Code CLI, pinned to $CLAUDE_PIN (Termux-safe pure-JS build)"
if ! claude --version >/dev/null 2>&1; then
  npm uninstall -g @anthropic-ai/claude-code >/dev/null 2>&1 || true
  npm install -g "@anthropic-ai/claude-code@${CLAUDE_PIN}" || \
    log "WARNING: Claude Code install failed — run it inside the Ubuntu chroot instead (see notes)"
else
  log "Claude Code already working: $(claude --version 2>/dev/null)"
fi

# --- 10. Useful directories ---
mkdir -p "$HOME/dev" "$HOME/scratch" "$HOME/notes"

# --- 11. Termux properties for better UX ---
log "Writing termux.properties for nicer keyboard"
cat > "$HOME/.termux/termux.properties" <<'EOF'
# Extra keys row — ESC, TAB, arrows, common keys
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]
# Don't open URLs in browser on long-press — just copy
url-select-method = aw
# Fullscreen mode for cyberdeck vibes
fullscreen = true
# Use volume keys as F1-F12 with CTRL
volume-keys = virtual
EOF

termux-reload-settings 2>/dev/null || true

# --- 12. Generate Termux's own SSH key so it can push to git etc. ---
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  log "Generating Termux ed25519 keypair"
  ssh-keygen -t ed25519 -N '' -C "psg1@cyberdeck" -f "$HOME/.ssh/id_ed25519"
fi

# --- 13. Final status ---
echo
log "==================== DONE ===================="
echo
echo "SSH server:    listening on $(ip -4 addr show wlan0 | awk '/inet /{print $2}' | cut -d/ -f1):$SSH_PORT"
echo "From client:   ssh -p $SSH_PORT $(whoami)@<this device's IP>"
echo "(Termux uid: $(id -u),  username: $(whoami))"
echo
echo "Termux pubkey (add to git hosts etc.):"
cat "$HOME/.ssh/id_ed25519.pub"
echo
echo "Reboot once to confirm termux-boot auto-starts sshd."
echo
