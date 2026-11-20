#!/usr/bin/env bash
# Post-install setup for Debian 13 (trixie) + GNOME 48 on a Surface Laptop 4.
#
# Run as your normal user from a terminal inside the GNOME session:
#   ./setup.sh
# It is safe to re-run. It works in two passes:
#   1st run: repos, linux-surface kernel + Secure Boot key, apps, settings.
#            Then reboot and enrol the key in the blue MokManager screen.
#   2nd run (while booted into the surface kernel): removes Debian's kernels
#            and pins them so they never come back.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$SCRIPT_DIR/files"

GIT_NAME="Tania Raven"
GIT_EMAIL="264633051+tgnra@users.noreply.github.com"
PLYMOUTH_THEME="bgrt"   # Surface logo + spinner. See: plymouth-set-default-theme --list
SWAPFILE_SIZE="8G"      # Only created if the system has no swap at all

FLATPAKS=(
  com.mattjakeman.ExtensionManager
  net.ankiweb.Anki
  com.calibre_ebook.calibre
  md.obsidian.Obsidian
)

EXTENSIONS=(
  blur-my-shell@aunetx
  caffeine@patapon.info
  appindicatorsupport@rgcjonas.gmail.com
)

# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }
root_write() { sudo install -d -m 0755 "$(dirname "$1")"; sudo tee "$1" >/dev/null; }
gs() { gsettings set "$@" || warn "gsettings set $* failed"; }

if [[ $EUID -eq 0 ]]; then
  echo "Run this as your normal user, not root. It uses sudo where needed." >&2
  exit 1
fi
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
  echo "Run this from a terminal inside your GNOME session (GNOME settings need it)." >&2
  exit 1
fi
# shellcheck source=/dev/null
. /etc/os-release
[[ ${VERSION_CODENAME:-} == trixie ]] || warn "Expected Debian trixie, found ${PRETTY_NAME:-unknown}."

sudo -v
# Keep sudo alive for the duration of the script.
( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &

# ---------------------------------------------------------------------------
log "Base tools"
sudo apt-get update
apt_install ca-certificates curl wget gpg dconf-cli git
sudo install -d -m 0755 /etc/apt/keyrings

# ---------------------------------------------------------------------------
log "Third-party APT repositories"

# linux-surface
curl -fsSL https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/linux-surface.gpg
root_write /etc/apt/sources.list.d/linux-surface.sources <<'EOF'
Types: deb
URIs: https://pkg.surfacelinux.com/debian
Suites: release
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/linux-surface.gpg
EOF

# Firefox (regular release, from Mozilla)
curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
  | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null
root_write /etc/apt/sources.list.d/mozilla.sources <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
root_write /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF

# VS Code. The keyring/file names match what the code package expects, and the
# debconf answer stops it from adding a duplicate repo of its own.
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
root_write /etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
echo "code code/add-microsoft-repo boolean false" | sudo debconf-set-selections

# Tailscale
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null

sudo apt-get update

# ---------------------------------------------------------------------------
log "linux-surface kernel and Secure Boot key"
apt_install linux-image-surface linux-headers-surface libwacom-surface iptsd
apt_install linux-surface-secureboot-mok

log "Firmware and microcode"
apt_install firmware-iwlwifi firmware-sof-signed firmware-misc-nonfree intel-microcode \
  || warn "Firmware install failed. Check that 'non-free-firmware' is enabled in your APT sources."

# ---------------------------------------------------------------------------
log "Applications and desktop packages"
apt_install \
  firefox code vlc vim papers tailscale \
  flatpak gnome-software-plugin-flatpak \
  ibus-libpinyin fonts-noto-cjk \
  gnome-shell-extension-blur-my-shell \
  gnome-shell-extension-caffeine \
  gnome-shell-extension-appindicator \
  gnome-console power-profiles-daemon \
  plymouth plymouth-themes \
  android-sdk-platform-tools-common

# Remove Firefox ESR, but only if nothing else would be removed with it.
if dpkg -s firefox-esr &>/dev/null; then
  mapfile -t would_remove < <(apt-get -s remove firefox-esr | awk '/^Remv /{print $2}')
  others=$(printf '%s\n' "${would_remove[@]}" | grep -v '^firefox-esr' || true)
  if [[ -z $others ]]; then
    sudo apt-get remove -y firefox-esr
  else
    warn "Not removing firefox-esr, because it would also remove: $(echo "$others" | tr '\n' ' ')"
  fi
fi

log "vim as default editor"
sudo update-alternatives --set editor /usr/bin/vim.basic
mkdir -p ~/.config/environment.d
cat > ~/.config/environment.d/50-editor.conf <<'EOF'
EDITOR=vim
VISUAL=vim
EOF
if ! grep -q 'taniadebian: editor' ~/.profile 2>/dev/null; then
  printf '\n# taniadebian: editor\nexport EDITOR=vim VISUAL=vim\n' >> ~/.profile
fi

# ---------------------------------------------------------------------------
log "Android Studio (/opt/android-studio)"
AS_DIR=/opt/android-studio
if [[ ! -x $AS_DIR/bin/studio && ! -x $AS_DIR/bin/studio.sh ]]; then
  AS_URL=${ANDROID_STUDIO_URL:-$(curl -fsSL https://developer.android.com/studio \
    | grep -oE 'https://[^"]+android-studio-[^"]+-linux\.tar\.gz' | head -n1 || true)}
  if [[ -n $AS_URL ]]; then
    tmp=$(mktemp -d)
    curl -fL --progress-bar "$AS_URL" -o "$tmp/android-studio.tar.gz"
    # Owned by you, so Android Studio's built-in updater can update itself.
    sudo install -d -o "$USER" -g "$(id -gn)" "$AS_DIR"
    tar -xzf "$tmp/android-studio.tar.gz" -C "$AS_DIR" --strip-components=1
    rm -rf "$tmp"
  else
    warn "Couldn't find the Android Studio download link. Re-run with ANDROID_STUDIO_URL=<tarball url> ./setup.sh"
  fi
fi
if [[ -d $AS_DIR/bin ]]; then
  AS_EXE=$AS_DIR/bin/studio
  [[ -x $AS_EXE ]] || AS_EXE=$AS_DIR/bin/studio.sh
  root_write /usr/local/share/applications/android-studio.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Android Studio
Comment=Android IDE
Exec="$AS_EXE" %f
Icon=$AS_DIR/bin/studio.svg
Categories=Development;IDE;
Terminal=false
StartupNotify=true
StartupWMClass=jetbrains-studio
EOF
fi
# kvm for the emulator, plugdev for adb to physical devices
sudo usermod -aG kvm,plugdev "$USER"

# ---------------------------------------------------------------------------
log "Flatpak apps"
sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
sudo flatpak install -y --noninteractive flathub "${FLATPAKS[@]}"

log "Strip file-type associations from Calibre and Obsidian"
install -D -m 0755 "$FILES/bin/flatpak-desktop-overrides" ~/.local/bin/flatpak-desktop-overrides
install -D -m 0644 -t ~/.config/systemd/user \
  "$FILES/systemd/user/flatpak-desktop-overrides.service" \
  "$FILES/systemd/user/flatpak-desktop-overrides.path"
~/.local/bin/flatpak-desktop-overrides

# ---------------------------------------------------------------------------
log "Claude Code"
if [[ ! -x ~/.local/bin/claude ]] && ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

# ---------------------------------------------------------------------------
log "Git"
git config --global user.name "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"

# ---------------------------------------------------------------------------
log "SSH config and automatic permission fixing"
sudo install -m 0755 "$FILES/bin/fix-ssh-perms" /usr/local/bin/fix-ssh-perms
sudo install -m 0644 "$FILES/systemd/system/fix-ssh-perms@.service" /etc/systemd/system/
install -D -m 0644 -t ~/.config/systemd/user \
  "$FILES/systemd/user/fix-ssh-perms.service" \
  "$FILES/systemd/user/fix-ssh-perms.path"
install -d -m 0700 ~/.ssh
if [[ -f ~/.ssh/config ]] && ! cmp -s "$FILES/ssh_config" ~/.ssh/config; then
  cp -p ~/.ssh/config ~/.ssh/config.bak."$(date +%Y%m%d%H%M%S)"
fi
install -m 0600 "$FILES/ssh_config" ~/.ssh/config
sudo systemctl daemon-reload
sudo systemctl enable "fix-ssh-perms@$USER.service"
/usr/local/bin/fix-ssh-perms

systemctl --user daemon-reload
systemctl --user enable --now \
  flatpak-desktop-overrides.service flatpak-desktop-overrides.path \
  fix-ssh-perms.service fix-ssh-perms.path

# ---------------------------------------------------------------------------
log "Keyboard: GB layout, Caps Lock = Ctrl, Right Alt = Compose (login screen + console)"
sudo localectl set-x11-keymap gb pc105 "" ctrl:nocaps,compose:ralt

# ---------------------------------------------------------------------------
log "Boot splash (plymouth) and quiet boot"
root_write /etc/default/grub.d/99-taniadebian.cfg <<'EOF'
# taniadebian: quiet boot with splash. Hold Esc/Shift during boot for the menu.
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=1
EOF
# Early KMS so the splash appears straight away at native resolution.
grep -qx 'i915' /etc/initramfs-tools/modules || echo i915 | sudo tee -a /etc/initramfs-tools/modules >/dev/null
if [[ -d /usr/share/plymouth/themes/$PLYMOUTH_THEME ]]; then
  sudo plymouth-set-default-theme "$PLYMOUTH_THEME"
else
  warn "Plymouth theme '$PLYMOUTH_THEME' isn't installed; keeping the default."
fi
sudo update-initramfs -u -k all
sudo update-grub

# ---------------------------------------------------------------------------
if [[ -z $(swapon --noheadings) && ! -e /swapfile ]]; then
  log "Swapfile ($SWAPFILE_SIZE)"
  sudo fallocate -l "$SWAPFILE_SIZE" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# ---------------------------------------------------------------------------
log "GNOME settings"

# Input: GB keyboard + Pinyin
gs org.gnome.desktop.input-sources sources "[('xkb', 'gb'), ('ibus', 'libpinyin')]"
gs org.gnome.desktop.input-sources xkb-options "['ctrl:nocaps', 'compose:ralt']"
dconf write /com/github/libpinyin/ibus-libpinyin/libpinyin/enable-cloud-input true \
  || warn "Couldn't enable Pinyin cloud input"

# Top bar
gs org.gnome.desktop.interface clock-show-weekday true
gs org.gnome.desktop.interface show-battery-percentage true

# Power
gs org.gnome.settings-daemon.plugins.power ambient-enabled false
gs org.gnome.settings-daemon.plugins.power power-button-action 'nothing'
gs org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 1800
powerprofilesctl set power-saver || warn "Couldn't set the power-saver profile"

# Files
gs org.gnome.nautilus.preferences default-folder-viewer 'list-view'
gs org.gnome.nautilus.list-view default-zoom-level 'small'

# Alt+Tab switches windows, not applications
gs org.gnome.desktop.wm.keybindings switch-applications "[]"
gs org.gnome.desktop.wm.keybindings switch-applications-backward "[]"
gs org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
gs org.gnome.desktop.wm.keybindings switch-windows-backward "['<Shift><Alt>Tab']"

# Super+Enter opens Console
KB=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/console/
gs org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$KB']"
gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB" name 'Console'
gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB" command 'kgx'
gs "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$KB" binding '<Super>Return'

# Dock
gs org.gnome.shell favorite-apps "['firefox.desktop', 'org.gnome.Nautilus.desktop']"

# Extensions (take effect at next login)
gs org.gnome.shell disable-user-extensions false
ext_list=$(printf "'%s', " "${EXTENSIONS[@]}")
gs org.gnome.shell enabled-extensions "[${ext_list%, }]"

# Default apps
xdg-settings set default-web-browser firefox.desktop || warn "Couldn't set Firefox as default browser"
xdg-mime default org.gnome.Papers.desktop application/pdf

# ---------------------------------------------------------------------------
if [[ $(uname -r) == *surface* ]]; then
  log "Running $(uname -r): removing Debian kernels and blocking them"
  root_write /etc/apt/preferences.d/no-debian-kernel <<'EOF'
# taniadebian: linux-surface is the only kernel on this machine.
# Delete this file to allow Debian kernels again.
Package: linux-image-* linux-headers-* linux-kbuild-*
Pin: release o=Debian
Pin-Priority: -1
EOF
  mapfile -t debian_kernels < <(
    dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'linux-image-*' 'linux-headers-*' 2>/dev/null \
      | awk '$2 == "installed" && $1 !~ /surface/ {print $1}'
  )
  if ((${#debian_kernels[@]})); then
    sudo apt-get purge -y "${debian_kernels[@]}"
    sudo apt-get autoremove -y
    sudo update-grub
  fi
  KERNEL_DONE=1
else
  KERNEL_DONE=0
fi

# ---------------------------------------------------------------------------
log "Done"
echo "Remaining steps:"
step=1
if ((KERNEL_DONE == 0)); then
  cat <<EOF
  $((step++)). Reboot. In the blue MokManager screen choose:
       Enroll MOK -> Continue -> Yes -> password: surface -> Reboot
  $((step++)). Log in and run ./setup.sh again. That removes the Debian kernel
       (only once you're running the surface kernel).
EOF
else
  echo "  $((step++)). Log out and back in (enables the extensions and new groups)."
fi
cat <<EOF
  $((step++)). Copy your SSH keys into ~/.ssh. Their permissions get fixed automatically.
  $((step++)). Run: sudo tailscale up
EOF
mokutil --sb-state 2>/dev/null || true
