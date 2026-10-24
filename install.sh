#!/usr/bin/env bash
# =============================================================================
#  CPTC workstation setup: Report Rex + rex-presence + VS Code + VPN
#
#  Built for a Kali Linux VM (VirtualBox .vdi / VMware) on a Windows host.
#  Also works on Debian/Ubuntu.
#
#  Put these files in the SAME folder as this script (or leave them in
#  ~/Downloads):
#     report-rex_<version>_linux_amd64.tar.gz
#     rex-presence-<version>.vsix
#     userNN.conf                (your WireGuard VPN config, optional)
#
#  Run:
#     chmod +x install.sh
#     sudo ./install.sh                     # asks for your rex username
#     sudo ./install.sh --user naomir       # rex username = first + last initial
#
#  Options:
#     --user NAME     rex-svr username (<first><last_initial>, lowercase)
#     --no-upgrade    skip the full system upgrade
#     --no-image      skip building the Report Rex Docker image (~3 GB, slow)
#     -h, --help      show this help
#
#  Safe to re-run: each step checks what's already there.
#  Full log: /var/log/cptc-setup.log
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- settings ---
REX_HOST="10.67.67.10"
REX_PORT="9443"
WG_IFACE="cptc"                       # VPN comes up with: sudo wg-quick up cptc
REX_INSTALL_DIR="/opt/report-rex"
LOG_FILE="/var/log/cptc-setup.log"

REX_USER=""
DO_UPGRADE=1
DO_IMAGE=1

# ------------------------------------------------------------------ output ---
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
WARNINGS=()
step() { printf '\n%s==> %s%s\n' "$C_B$C_C" "$*" "$C_0"; }
ok()   { printf '%s  ✔ %s%s\n' "$C_G" "$*" "$C_0"; }
warn() { printf '%s  ! %s%s\n' "$C_Y" "$*" "$C_0"; WARNINGS+=("$*"); }
die()  { printf '%s  ✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }
trap 'printf "%s  ✘ Failed at line %s: %s%s\n  Full log: %s\n" "$C_R" "$LINENO" "$BASH_COMMAND" "$C_0" "$LOG_FILE" >&2' ERR

usage() { sed -n '3,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0; }

# -------------------------------------------------------------------- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)       REX_USER="${2:-}"; shift 2 ;;
    --user=*)     REX_USER="${1#*=}"; shift ;;
    --no-upgrade) DO_UPGRADE=0; shift ;;
    --no-image)   DO_IMAGE=0; shift ;;
    -h|--help)    usage ;;
    *)            die "Unknown option: $1 (try --help)" ;;
  esac
done

# --------------------------------------------------------------- preflight ---
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo ./install.sh"
TARGET_USER="${SUDO_USER:-}"
[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] \
  || die "Run this with sudo from your normal account, not from a root shell."
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
as_user() { sudo -u "$TARGET_USER" -H "$@"; }

[[ "$(uname -m)" == "x86_64" ]] \
  || die "Report Rex ships as linux_amd64 only; this machine is $(uname -m)."

touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "---- cptc-setup run $(date -Is) for $TARGET_USER ----"

IS_KALI=0
grep -qi '^ID=kali' /etc/os-release && IS_KALI=1

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Look for an input file next to the script first, then in ~/Downloads.
find_input() {
  local pattern="$1" dir match
  for dir in "$SCRIPT_DIR" "$TARGET_HOME/Downloads"; do
    match="$(find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | sort -V | tail -n1)"
    if [[ -n "$match" ]]; then echo "$match"; return 0; fi
  done
  return 1
}

REX_TARBALL="$(find_input 'report-rex_*_linux_amd64.tar.gz' || true)"
REX_VSIX="$(find_input 'rex-presence-*.vsix' || true)"
WG_CONF="$(find_input 'user[0-9]*.conf' || true)"

[[ -n "$REX_TARBALL" ]] \
  || die "Can't find report-rex_*_linux_amd64.tar.gz next to this script or in ~/Downloads."

if [[ -z "$REX_USER" && -t 0 ]]; then
  read -rp "rex-svr username (first name + last initial, e.g. naomir): " REX_USER
fi
REX_USER="$(printf '%s' "$REX_USER" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

step "Plan"
echo "  User:        $TARGET_USER ($TARGET_HOME)"
echo "  OS:          $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  VM type:     $(systemd-detect-virt 2>/dev/null || echo unknown)"
echo "  Report Rex:  $REX_TARBALL"
echo "  Extension:   ${REX_VSIX:-<not found, will skip>}"
echo "  VPN config:  ${WG_CONF:-<not found, will skip>}"
echo "  rex user:    ${REX_USER:-<not set; edit ~/.cptc_aliases later>}"

AVAIL_GB="$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')"
if (( AVAIL_GB < 15 )); then
  warn "Only ${AVAIL_GB} GB free on /. The Docker image alone needs ~3-4 GB; grow the VM disk if things fail."
fi

# Install only the packages this distro actually has; report the rest.
install_available() {
  local want=() skip=() p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then want+=("$p"); else skip+=("$p"); fi
  done
  if ((${#want[@]})); then
    "${APT[@]}" install "${want[@]}" || {
      warn "Bulk install hit an error; retrying one package at a time"
      for p in "${want[@]}"; do "${APT[@]}" install "$p" || warn "Could not install $p"; done
    }
  fi
  if ((${#skip[@]})); then echo "  (not available here, skipped: ${skip[*]})"; fi
  return 0
}

# ------------------------------------------------------------ 1. apt update ---
step "Updating package lists"
if ! apt-get update; then
  if [[ $IS_KALI -eq 1 ]]; then
    warn "apt update failed; refreshing the Kali archive signing key and retrying"
    wget -qO /usr/share/keyrings/kali-archive-keyring.gpg https://archive.kali.org/archive-keyring.gpg
    apt-get update
  else
    die "apt-get update failed. Check the VM's network (VirtualBox: Settings > Network > NAT)."
  fi
fi
ok "Package lists updated"

"${APT[@]}" install ca-certificates curl wget gpg git unzip

if [[ $DO_UPGRADE -eq 1 ]]; then
  step "Upgrading the system (can take a while on a fresh VM)"
  "${APT[@]}" full-upgrade
  ok "System upgraded"
fi

# ---------------------------------------------------- 2. VM guest additions ---
step "VM integration (shared clipboard, auto screen resize)"
case "$(systemd-detect-virt 2>/dev/null || true)" in
  oracle)    install_available virtualbox-guest-x11;  ok "VirtualBox guest additions installed (reboot to activate)" ;;
  vmware)    install_available open-vm-tools-desktop; ok "VMware tools installed (reboot to activate)" ;;
  microsoft) install_available hyperv-daemons;        ok "Hyper-V integration installed" ;;
  *)         echo "  No supported hypervisor detected; skipping." ;;
esac

# ---------------------------------------------------------------- 3. Docker ---
step "Docker (Report Rex builds PDFs inside a container)"
if ! command -v docker >/dev/null 2>&1; then
  install_available docker.io docker-buildx docker-cli
fi
systemctl enable --now docker >/dev/null 2>&1 || warn "Couldn't start Docker; try: sudo systemctl start docker"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  ok "Docker ready"
else
  usermod -aG docker "$TARGET_USER"
  ok "Added $TARGET_USER to the docker group (active after you log out and back in)"
fi

# ------------------------------------------------------------ 4. Report Rex ---
step "Installing Report Rex"
# Kali ships an unrelated Perl tool also called `rex` that grabs the command.
if dpkg -s rex >/dev/null 2>&1; then
  "${APT[@]}" remove rex
  ok "Removed the unrelated Perl 'rex' package"
fi
# Clean up a manual install (the folder that was moved into /usr/local/bin).
[[ -d /usr/local/bin/report-rex ]] && rm -rf /usr/local/bin/report-rex
[[ -L /usr/local/bin/rex ]] && rm -f /usr/local/bin/rex

rm -rf "$REX_INSTALL_DIR"
install -d -m 0755 "$REX_INSTALL_DIR"
tar -xzf "$REX_TARBALL" -C "$REX_INSTALL_DIR" --no-same-owner
chmod 0755 "$REX_INSTALL_DIR/rex" "$REX_INSTALL_DIR/rex-svr"
ln -sf "$REX_INSTALL_DIR/rex"     /usr/local/bin/rex
ln -sf "$REX_INSTALL_DIR/rex-svr" /usr/local/bin/rex-svr
hash -r

REX_VERSION="$(/usr/local/bin/rex version 2>/dev/null | head -n1 || true)"
ok "rex installed: ${REX_VERSION:-unknown version} (/usr/local/bin/rex)"

# Tab completion for zsh (Kali's default shell) and bash.
install -d /usr/local/share/zsh/site-functions /etc/bash_completion.d
/usr/local/bin/rex completion zsh  > /usr/local/share/zsh/site-functions/_rex 2>/dev/null || true
/usr/local/bin/rex completion bash > /etc/bash_completion.d/rex             2>/dev/null || true

# `rex report build --password` (encrypted PDFs) needs qpdf.
install_available qpdf

if [[ $DO_IMAGE -eq 1 ]]; then
  step "Building the Report Rex Docker image (pulls TeX Live; 10-20 min)"
  if /usr/local/bin/rex image build; then
    ok "Docker image built"
  else
    warn "Image build failed. Retry later with: sudo rex image build"
  fi
fi

# --------------------------------------------------------------- 5. VS Code ---
step "Installing VS Code"
if ! command -v code >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor --yes -o /etc/apt/keyrings/packages.microsoft.gpg
  chmod 0644 /etc/apt/keyrings/packages.microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list
  # Stop the package from adding a second, conflicting copy of the repo.
  echo "code code/add-microsoft-repo boolean false" | debconf-set-selections
  apt-get update
  "${APT[@]}" install code
fi
ok "VS Code $(code --version 2>/dev/null | head -n1 || true)"

step "Installing VS Code extensions"
if [[ -n "$REX_VSIX" ]]; then
  if as_user code --install-extension "$REX_VSIX" --force; then
    ok "rex-presence installed"
  else
    warn "rex-presence install failed; retry: code --install-extension \"$REX_VSIX\""
  fi
else
  warn "rex-presence .vsix not found; install later with: code --install-extension <file>.vsix"
fi
for ext in redhat.vscode-yaml yzhang.markdown-all-in-one streetsidesoftware.code-spell-checker; do
  if as_user code --install-extension "$ext" --force >/dev/null 2>&1; then
    ok "$ext"
  else
    warn "Couldn't install VS Code extension $ext"
  fi
done

# -------------------------------------------------------------- 6. VPN ---
step "WireGuard VPN"
install_available wireguard-tools
if [[ -n "$WG_CONF" ]]; then
  install -d -m 0700 /etc/wireguard
  install -m 0600 -o root -g root "$WG_CONF" "/etc/wireguard/${WG_IFACE}.conf"
  ok "VPN config installed as /etc/wireguard/${WG_IFACE}.conf (bring it up with: vpnup)"
  echo "  The config holds your private key. Don't commit it or post it anywhere."
else
  warn "No userNN.conf found; VPN not configured. Put it next to install.sh and re-run."
fi

# ----------------------------------------------------- 7. Workspace & shell ---
step "Report workspace and shell shortcuts"
REPORT_DIR="$TARGET_HOME/cptc/report"
as_user mkdir -p "$TARGET_HOME/cptc"/{report,notes,screenshots}

# Pre-fill the rex-presence settings for this workspace (password is set in the
# extension's panel, never in a file). Sync starts OFF: turn it on in the panel.
SETTINGS="$REPORT_DIR/.vscode/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
  as_user mkdir -p "$REPORT_DIR/.vscode"
  cat > "$SETTINGS" <<EOF
{
  "report-rex.host": "$REX_HOST",
  "report-rex.port": $REX_PORT,
  "report-rex.username": "$REX_USER",
  "report-rex.insecure": true,
  "report-rex.sync.enabled": false
}
EOF
  chown "$TARGET_USER:$TARGET_GROUP" "$SETTINGS"
  ok "VS Code workspace settings written to ~/cptc/report/.vscode/settings.json"
else
  ok "Existing VS Code workspace settings left as-is"
fi

ALIASES="$TARGET_HOME/.cptc_aliases"
cat > "$ALIASES" <<EOF
# Written by cptc install.sh. Safe to edit.
REX_HOST="$REX_HOST"
REX_USER="${REX_USER:-CHANGE_ME}"   # <first><last_initial>

alias vpnup='sudo wg-quick up $WG_IFACE'
alias vpndown='sudo wg-quick down $WG_IFACE'
alias vpnstatus='sudo wg show'
alias cptc='cd ~/cptc'

# rex prompts for the shared password; --insecure trusts the server's
# self-signed cert (OK over the team VPN). Use either this OR the VS Code
# panel's Sync toggle, not both at once.
rexsync()   { cd ~/cptc/report && rex sync   --dir . --host "\$REX_HOST" --username "\$REX_USER" --insecure "\$@"; }
rexstatus() { rex status --host "\$REX_HOST" --username "\$REX_USER" --insecure "\$@"; }
rexdraft()  { rex report build --dir "\${1:-.}" --output report.pdf; }
rexfinal()  { rex report build --dir "\${1:-.}" --output report.pdf --final; }
EOF
chown "$TARGET_USER:$TARGET_GROUP" "$ALIASES"

for rc in "$TARGET_HOME/.zshrc" "$TARGET_HOME/.bashrc"; do
  [[ -f "$rc" ]] || continue
  grep -q '.cptc_aliases' "$rc" || printf '\n[ -f ~/.cptc_aliases ] && . ~/.cptc_aliases\n' >> "$rc"
done
ok "Shortcuts added: vpnup, vpndown, vpnstatus, rexsync, rexstatus, rexdraft, rexfinal"

# ----------------------------------------------------------------- summary ---
step "Done"
if ((${#WARNINGS[@]})); then
  printf '%sThings to look at:%s\n' "$C_Y" "$C_0"
  for w in "${WARNINGS[@]}"; do echo "  - $w"; done
  echo
fi
cat <<EOF
Next steps:
  1. Reboot the VM (activates the docker group and guest additions):  sudo reboot
  2. Open a terminal and connect:     vpnup && rexstatus
  3. Pull the team report:            rexsync
     ...or open it in VS Code:        code ~/cptc/report
     then in the Report Rex panel (Explorer sidebar): Set Password, then toggle Sync on.
  4. Build a draft PDF from the report folder:   rexdraft

Log saved to $LOG_FILE
EOF
