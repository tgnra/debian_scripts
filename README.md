# taniadebian

Post-install setup for Debian 13 "trixie" (GNOME 48) on a Surface Laptop 4.

## 1. Before installing

- In Surface UEFI (hold Volume Up while powering on), go to **Security → Secure Boot → Change configuration** and choose **Microsoft & 3rd party CA**. Debian's shim needs this.
- Write the Debian 13 netinst ISO to a USB stick.

## 2. Installer choices

- **Root password: leave it blank.** Your user then gets `sudo`, which the script relies on.
- **Partitioning: Manual.** Create:
  - a 1 GB **EFI System Partition**
  - the rest as **ext4** mounted at `/`
  - no swap partition (the script creates an 8 GB `/swapfile`)
- **Software selection:** *GNOME* and *standard system utilities*.

## 3. After the first boot

```sh
git clone <this repo> ~/Code/taniadebian   # or copy the folder over
cd ~/Code/taniadebian
./setup.sh
```

1. Reboot. In the blue **MokManager** screen choose **Enroll MOK → Continue → Yes**, enter the password `surface`, then choose **Reboot**.
2. Log in and run `./setup.sh` again. Now that you're on the surface kernel, it removes Debian's kernel and pins it so updates never bring it back.
3. Copy your SSH keys into `~/.ssh`. Permissions are fixed automatically.
4. Run `sudo tailscale up`.

## What it sets up

| Area | Details |
|---|---|
| Kernel | linux-surface only (with libwacom-surface and iptsd), Secure Boot key via MOK, Debian kernels pinned to `-1` in `/etc/apt/preferences.d/no-debian-kernel` |
| Boot | Plymouth `bgrt` splash, `quiet splash`, hidden GRUB menu (hold Esc/Shift for it; the previous surface kernel is under *Advanced options*) |
| APT apps | Firefox (Mozilla repo, replaces ESR), VS Code (Microsoft repo), VLC, vim (default `editor`, `$EDITOR`, `$VISUAL`), Papers (default PDF viewer), Tailscale, Android Studio (official tarball in `/opt/android-studio`, user-owned so it can self-update) |
| Flatpak apps | Extension Manager, Anki, Calibre, Obsidian |
| Other | Claude Code (native installer, self-updating) |
| File associations | Calibre and Obsidian claim no file types. Their `calibre://`/`obsidian://` link handlers are kept, and Calibre's extra launchers are hidden. Re-applied after every Flatpak update by `flatpak-desktop-overrides.path` |
| Extensions | Blur My Shell, Caffeine, AppIndicator/KStatusNotifierItem (Debian packages) |
| Keyboard | GB layout, Caps Lock = Ctrl, Right Alt = Compose. Applies in GNOME, at the login screen and on the console. Pinyin (ibus-libpinyin, cloud input on) |
| GNOME | Weekday in clock, battery %, no auto brightness, power button does nothing, suspend after 30 min on AC, power-saver profile, Files in list view with small icons, Alt+Tab switches windows, Super+Enter opens Console, dock: Firefox + Files |
| SSH | `~/.ssh/config` installed. Permissions fixed at boot (including ownership), at login, and whenever files in `~/.ssh` change |
| Git | user.name / user.email |

To change the splash theme, edit `PLYMOUTH_THEME` in `setup.sh` (`plymouth-set-default-theme --list` shows the options).
