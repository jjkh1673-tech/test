# CloudDesk-RDP

A lightweight XFCE + xRDP remote desktop you can install on a small Linux VPS in one command — built for **file management, browser work and terminal access** on 1 GB RAM / 1 vCPU machines.

<p>
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/badge/OS-Debian%2012%2F13%20%C2%B7%20Ubuntu%2022.04%2F24.04-blue" alt="Debian and Ubuntu"/>
  <img src="https://img.shields.io/badge/Desktop-XFCE-228DD6" alt="XFCE"/>
  <img src="https://img.shields.io/badge/RDP-xrdp%20%2B%20Xorg-0078D4" alt="xrdp"/>
  <img src="https://img.shields.io/badge/Browser-Firefox-FF7139" alt="Firefox"/>
</p>

---

## What this is

CloudDesk-RDP turns a minimal Debian or Ubuntu cloud server into a small remote desktop that you reach with any standard RDP client (Windows `mstsc`, Remmina, macOS Windows App, etc.). It installs only what the job needs: the xrdp server, a minimal XFCE desktop, Firefox, the Thunar file manager, a terminal and a tuned `nano` editor — and deliberately nothing else.

The project is optimized for the boring but important cases: browsing cloud storage in Firefox, moving and organizing files (GUI or terminal), and editing configs over a long-running remote session on a cheap, low-memory VPS. There is no office suite, no media center, no database, no snap daemon and no desktop bloat to eat your RAM.

Two deployment paths are included:

1. **Native installer (recommended)** — `install.sh` prepares a real Debian/Ubuntu VPS. Uses systemd, survives reboots, ships with an uninstaller.
2. **Container image (secondary)** — the original `Dockerfile`/`start.sh` path (e.g. for Railway) is preserved and hardened: it refuses to start unless you provide `RDP_PASSWORD`.

## What you get

- **Native RDP access** via `xrdp` + `xorgxrdp` on TCP 3389, enabled as a systemd service at boot
- **Minimal XFCE desktop**: slim top panel (applications menu, window buttons, tray, clock), compositing disabled
- **macOS-inspired Plank dock** at the bottom with exactly three launchers: **Firefox, Terminal, Files** — running apps appear next to them
- **Clean desktop** with six core icons: **Home, Trash, Settings, Firefox, Files, Terminal**, plus an original generated wallpaper (37 KB)
- **Firefox** installed the right way per distro (real `.deb` from Mozilla's repo on Ubuntu 22.04/24.04 — no snap; ESR on Debian), with policies that disable telemetry, Pocket and cosmetic animations while keeping normal browsing, logins, uploads and downloads intact
- **Thunar file manager** with archive support (xarchiver) and a `~/Workspace` folder convention
- **Tuned nano**: line numbers, mouse click-to-place-cursor, 4-space tabs, soft wrap, auto-indent, bracket-pair highlighting and extension-aware syntax highlighting
- **`clouddesk` CLI** for status / start / stop / restart / logs
- **Optional automatic swapfile** on machines with under 2 GB RAM (survives Firefox memory spikes)
- **Clean uninstaller** that restores every file it backed up and removes the packages it added

## Requirements

| Item | Requirement |
| :--- | :--- |
| Supported OS | Debian 12 (bookworm), Debian 13 (trixie), Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble). Ubuntu 20.04 works but is past standard support. Other distros: `--force-os` (unsupported). |
| Architecture | x86_64 or aarch64 |
| RAM | 1 GB works (an automatic 2 GB swapfile is added when RAM < 2 GB); 2 GB is comfortable |
| CPU | 1 vCPU is enough |
| Disk | ~2 GB free for packages and the desktop |
| Privileges | root (run with `sudo`) |
| Network | Internet access to the distro mirrors (and to `packages.mozilla.org` on Ubuntu 22.04/24.04) |
| Client | Any RDP client. The login dialog's session type must be **Xorg** (the default). |

## Quick Start

On a fresh Debian 12/13 or Ubuntu 22.04/24.04 VPS, as root:

```bash
git clone https://github.com/jjkh1673-tech/CloudDesk-RDP.git
cd CloudDesk-RDP
sudo ./install.sh
```

The installer asks for a desktop username and password, installs everything, starts the RDP service and prints your server IP. Then connect from your PC:

```
Windows: Win+R -> mstsc -> enter <server-ip>:3389
```

That's it. The rest of this document explains the details.

## Installation

```bash
# 1. Get the project
git clone https://github.com/jjkh1673-tech/CloudDesk-RDP.git
cd CloudDesk-RDP

# 2. Review what it will do (optional, no changes made)
sudo ./install.sh --dry-run

# 3. Install interactively (prompts for username + password)
sudo ./install.sh
```

Non-interactive installation (automation-friendly, keeps the password out of your shell history):

```bash
echo 'A-Strong-Password-Here' | sudo ./install.sh --user desk --password-stdin
```

All installer options:

```text
--user NAME        Desktop login username (default: clouddesk, or $CLOUDDESK_USER)
--password-stdin   Read the new user's password from stdin
--no-sudo          Do NOT add the desktop user to the sudo group
--no-swap          Never create a swapfile
--swap-size SIZE   Swapfile size, e.g. 2G or 512M (default: 2G)
--force-os         Proceed on an unsupported distro (best effort, no guarantees)
--dry-run          Show every planned action without changing the system
-h, --help         Help
-V, --version      Version
```

Notes:

- The installer is **safe to re-run**. It skips finished work, never overwrites an original file without backing it up first, and never touches your existing SSH or display-manager configuration.
- Everything it changes is recorded in `/var/lib/clouddesk/manifest` and reversible with `uninstall.sh`.
- Originals of modified files are stored under `/var/backups/clouddesk/<timestamp>/`.
- The full log lands in `/var/log/clouddesk-install.log`.

### What the installer actually does

1. Detects OS/architecture and checks network access
2. Installs a minimal package set: `xrdp`, `xorgxrdp`, XFCE core (`xfce4-session`, `xfwm4`, `xfdesktop4`, `xfce4-panel`, `xfce4-settings`), `thunar`, `xfce4-terminal`, `gvfs`, fonts, `zip`/`unzip` — and tries optional extras (`plank`, `greybird-gtk-theme`, `xarchiver`, `lxpolkit`, `xterm`) without failing if a distro lacks one
3. Installs Firefox: `firefox-esr` (Debian), `firefox` (Ubuntu 20.04), or Mozilla's official APT repo pinned above the snap version (Ubuntu 22.04/24.04)
4. Creates the desktop user (and offers sudo membership)
5. Writes the session launcher `/etc/xrdp/startwm.sh`, applies gentle `xrdp.ini` tweaks (`ls_title`, `max_bpp=24`), adds polkit rules, installs Firefox policies, applies the managed nano block to `/etc/nanorc`, deploys desktop/dock configuration to the user home and `/etc/skel`
6. Enables and starts `xrdp` + `xrdp-sesman` via systemd
7. Adds a swapfile only if RAM < 2 GB and no swap is active
8. Runs a full validation pass (commands, files, services, TCP 3389) and prints the summary

## First Login

1. Open your RDP client and connect to `<server-ip>:3389`
2. In the xrdp login dialog: **Session = Xorg**, enter your desktop username and password
3. You will see: the indigo wallpaper, a slim top panel, the dock at the bottom, and the desktop icons (Home, Trash, Settings, Firefox, Files, Terminal)
4. Open Firefox from the dock or desktop and go to work

If you accidentally pick a non-Xorg session type and get a black screen, log out and choose **Xorg**.

## Desktop

The desktop is intentionally minimal:

- **Dock (bottom, Plank)**: Firefox, Terminal, Files — locked, centered, intellihide. Running applications appear in the dock automatically; no other launchers are added.
- **Panel (top)**: applications menu, icon-only window buttons, system tray, clock. Kept because window management over RDP is easier with a taskbar.
- **Desktop icons**: Home (your files), Trash, Settings, Firefox, Files, Terminal.
- Compositing and animations are disabled — they only cost CPU/RAM over a remote link and provide no benefit without a GPU.
- Right-click on the desktop still opens the standard XFCE menu for settings if you ever want them.

Dock settings live in `~/.config/plank/dock1/settings` and `~/.config/plank/dock1/launchers/` — edit and restart your session to apply.

## Files & Browser Workflow

This project assumes a simple loop, matching the priorities of the project: browser in, files organized, terminal for everything else.

1. **Firefox** → open your cloud storage (Google Drive, OneDrive, Mega, Dropbox, GitHub...) and download or upload files. Downloads land in `~/Downloads` by default.
2. **Files (Thunar)** → browse `~/Downloads`, drag/copy things into `~/Workspace` (your working folder), rename, delete to Trash, right-click → *Extract* for archives (xarchiver).
3. **Terminal** → bulk or advanced operations:

```bash
ls -lah ~/Downloads            # inspect downloads
mv ~/Downloads/report.pdf ~/Workspace/
unzip archive.zip -d ~/Workspace/
zip -r backup.zip ~/Workspace/
df -h && free -h               # disk and RAM
nano ~/Workspace/notes.md      # tuned editor
```

Firefox can read and upload from anywhere in your home directory — cloud-storage web apps work exactly like on a local machine. Nothing is proxied or sandboxed away from your real filesystem.

## Configuration

Everything lives in a few predictable places:

| What | Where |
| :--- | :--- |
| Session launcher | `/etc/xrdp/startwm.sh` |
| xrdp settings (only `ls_title` and `max_bpp` are touched) | `/etc/xrdp/xrdp.ini` |
| Firefox policies (telemetry/Pocket/animations off) | `/etc/firefox/policies/policies.json` (also `/etc/firefox-esr/policies/` on Debian) |
| Nano settings (managed block) | `/etc/nanorc` (between `>>>` / `<<<` CloudDesk markers) |
| XFCE desktop config | `~/.config/xfce4/xfconf/xfce-perchannel-xml/*.xml` |
| Plank dock | `~/.config/plank/dock1/` |
| Wallpaper | `/usr/share/clouddesk/wallpaper.png` |
| Install manifest | `/var/lib/clouddesk/manifest` |
| Backups | `/var/backups/clouddesk/` |
| Install log | `/var/log/clouddesk-install.log` |

Installer-time environment variables: `CLOUDDESK_USER` (default username) and `CLOUDDESK_PASSWORD` (non-interactive password — prefer `--password-stdin`).

## Useful Commands

```bash
clouddesk status              # services + TCP 3389 check (no root needed)
sudo clouddesk start          # start xrdp + sesman
sudo clouddesk stop           # stop them
sudo clouddesk restart        # restart after config changes
clouddesk logs                # tail xrdp + sesman logs
clouddesk logs sesman         # session manager log only
sudo clouddesk logs install   # installer log
sudo ./uninstall.sh           # remove CloudDesk-RDP (asks before purging packages)
sudo ./uninstall.sh --yes     # fully non-interactive removal
sudo ./uninstall.sh --remove-user   # also delete the desktop user + home
```

The uninstaller restores every backed-up original file, removes files it created, strips the nano block, removes the swapfile and fstab entry it added, and purges only the packages the installer actually introduced (verified against a pre-install package snapshot).

## Troubleshooting

Real problems and their fixes:

**Cannot connect at all / connection refused**
Check the service and the port on the server: `clouddesk status`. If xrdp is running but the port is unreachable from outside, it is almost always a cloud-provider firewall or security group — open TCP 3389 (or restrict it to your IP, see Security). With ufw: `sudo ufw allow 3389/tcp`.

**Black screen or immediate disconnect after login**
Pick session type **Xorg** in the xrdp login box. If it still fails: `clouddesk logs sesman` usually shows the reason (most commonly a leftover session of the same user — log out other sessions or reboot). Check that `/etc/xrdp/startwm.sh` is intact (it must contain `dbus-run-session`).

**"Password failed" but the password is correct**
The xrdp login is a Linux login: use the username you chose during installation (e.g. `clouddesk`), not `root`, and note that the dialog is case-sensitive. Reset it with: `sudo passwd <username>`.

**Dock (plank) missing**
Plank is an optional package; on the rare distro without it the installer continues without the dock (the panel still works). Install it with `sudo apt install plank`, log out and back in.

**Slow or laggy sessions**
Lower the color depth to 16-bit in your RDP client, reduce the client window resolution, and avoid heavy WebGL sites. `max_bpp` is already set to 24 server-side. One or two Firefox tabs are fine on 1 GB; twenty are not.

**Snap Firefox got installed anyway (Ubuntu)**
This means the Mozilla repo could not be reached during install. Re-running the installer sets it up and pins Mozilla's `.deb` above the snap; you can then remove the snap with `sudo snap remove firefox`.

**nano prints deprecation warnings for options**
Your nano is older/newer than expected. The installer writes a version-compatible block — re-run `sudo ./install.sh` and it will regenerate the correct one.

**Check overall health**
`clouddesk status`, then `journalctl -u xrdp -u xrdp-sesman -e`, then `free -h` / `df -h`.

## Lightweight Design

Why this stays small enough for a 1 GB / 1 vCPU VPS:

- No `xfce4` meta-package — just the six XFCE pieces a session needs
- No snapd, no tracker/indexers, no screensaver, no power manager, no thumbnail daemon, no audio stack (add via Extra Applications if needed)
- Compositing and animations disabled at the window-manager, GTK and Firefox levels
- Firefox as a real `.deb` instead of the snap (the snap's layered filesystem and background refreshes cost RAM and I/O)
- A 37 KB generated wallpaper instead of a wallpapers collection
- One dock (plank, ~20 MB class RSS) plus one slim panel; no duplicate panel stacks
- An automatic swapfile absorbs browser memory spikes instead of OOM-killing your session

Don't take our word for it — measure your own box with `free -h` before and after installing, and with `htop` during use. Modern websites are heavy; if you keep 20 tabs of video sites open, no lightweight desktop will save you.

## Extra Applications

Deliberately **not** preinstalled — add only what you need (all commands inside the RDP terminal):

| App | Why you might need it | Install | Approx. cost |
| :--- | :--- | :--- | :--- |
| `tumbler` | Thumbnails in Thunar | `sudo apt install tumbler` | small; a background daemon |
| `p7zip-full` | 7z archives | `sudo apt install p7zip-full` | ~5 MB |
| `file-roller` | Fuller archive GUI (xarchiver already covers zip/tar) | `sudo apt install file-roller` | moderate (GNOME deps) |
| `papirus-icon-theme` | Prettier icons | `sudo apt install papirus-icon-theme` then set in Settings → Appearance | ~350 MB disk, minimal RAM |
| audio in RDP | Hear sound in the session | `sudo apt install pulseaudio xrdp-pulseaudio-installer pavucontrol` (package name varies by distro) | moderate; a per-session pulseaudio |
| LibreOffice | Document editing | `sudo apt install libreoffice` | heavy (hundreds of MB, slow first start on 1 GB) — prefer browser-based office tools on this class of VPS |
| `fail2ban` | Brute-force protection for exposed RDP | `sudo apt install fail2ban` (a jail for xrdp goes in `/etc/fail2ban/jail.local`) | small; recommended if port 3389 is public |

Temporary tools can also be installed ad hoc through the terminal or fetched directly in Firefox; anything you install yourself persists until you remove it (on a VPS) or until the container is rebuilt (on the container path).

## Container deployment (secondary path)

The repository keeps the original single-container deployment for platforms like Railway:

```bash
docker build -t clouddesk .
docker run -d -p 3389:3389 -e RDP_PASSWORD='A-Strong-Password-Here' --name clouddesk clouddesk
```

`RDP_PASSWORD` is **required** — the container exits with instructions if it is missing. There is no default password and never was one in this version. The container path shares the same configuration files as the native installer (single source of truth in `config/`).

## Security

Read this before exposing port 3389 to the internet:

- **RDP on a public IP is brute-force bait.** At minimum use a long, unique password for the desktop user. Better: restrict TCP 3389 in your provider firewall to your own IP.
- **Safer than opening the port:** tunnel RDP over SSH — `ssh -L 3389:localhost:3389 user@server`, then connect your RDP client to `localhost:3389`. You get SSH's crypto and the server's port 3389 never faces the internet.
- Install `fail2ban` if the port must stay public (see Extra Applications).
- The installer never disables authentication, never stores passwords in files, and the container path requires the password via environment variable at runtime. Passwords set through `--password-stdin` or the interactive prompt never touch the install log.
- Keep the system patched: `sudo apt update && sudo apt upgrade` regularly. xrdp and Firefox receive security updates through the normal repositories (Mozilla's repo on Ubuntu 22.04/24.04).
- The desktop user gets sudo by default (with its password). Use `--no-sudo` if you do not want that.
- xrdp uses TLS with self-signed certificates generated on first start; your RDP client will show a certificate warning once — expected for self-signed certs.

## Project Structure

```text
CloudDesk-RDP/
├── install.sh              # Native VPS installer (idempotent, with --dry-run)
├── uninstall.sh            # Reverts installation via the manifest + backups
├── bin/clouddesk           # Helper CLI: status/start/stop/restart/logs
├── config/
│   ├── xrdp/startwm.sh     # Session launcher (dbus-run-session -> XFCE)
│   ├── firefox/policies.json
│   ├── nano/nanorc.block   # Managed nano block (version-aware options)
│   ├── xfce4/*.xml         # Panel, desktop, window manager, xsettings
│   ├── plank/              # Dock settings + launcher templates
│   ├── desktop/*.desktop   # Files / Settings / Terminal launchers
│   └── polkit/             # colord prompt fix (.rules + .pkla)
├── assets/
│   ├── wallpaper.png       # Original generated wallpaper (37 KB)
│   └── src/generate_wallpaper.py
├── tests/
│   ├── run-tests.sh        # Static suite (syntax, lint, integrity, secrets)
│   ├── unit-tests.sh       # Function-level tests of the installer
│   ├── test-docker.sh      # Full e2e harness (requires docker)
│   └── docker/             # Debian 12 / Ubuntu 24.04 test images + verifiers
├── Dockerfile              # Container path (Ubuntu 24.04 base)
├── start.sh                # Container entrypoint (RDP_PASSWORD required)
├── .dockerignore
├── LICENSE                 # MIT
└── README.md
```

## Verification

What was actually tested with the shipped code (see `tests/`), on the build environment (Debian 13, no root, no docker):

- `shellcheck` v0.10.0, style severity, across all 10 shell scripts: **clean**
- `tests/unit-tests.sh` — 31 assertions: OS detection matrix (Debian 11/12/13, Ubuntu 20.04/22.04/24.04, unsupported + `--force-os`), argument parsing (including `--password-stdin`), swap-size validation, nano version branches, package list sanity (required present, heavy packages absent), template substitution, help text: **31/31 pass**
- `tests/run-tests.sh` — 51 checks: `bash -n` on every script, shellcheck, executable-bit audit, JSON/XML/desktop-entry validation, placeholder hygiene, hardcoded-secret scan (including a ban on the project's historic default password), installer→file cross-references, wallpaper integrity, CRLF check: **51/51 pass**
- Full installer `--dry-run` on Debian 13: **completes end-to-end, exit 0, correct summary**
- `clouddesk` CLI and `uninstall.sh --dry-run` behavior checks: **pass**
- Two real installer bugs were caught by these tests and fixed before release (see git history): a `--password-stdin` argument-parsing loop and a dry-run crash when the desktop user does not exist yet.

Provided but **not executed** in the build environment (no docker available there — run them on any docker-capable machine):

- `tests/test-docker.sh` builds Debian 12 and Ubuntu 24.04 images, runs the real installer inside, verifies every artifact, starts xrdp and checks that TCP 3389 listens, re-runs the installer for idempotency, then uninstalls and verifies the removal.
- An actual RDP client login against a live VPS.

## License

MIT — see [LICENSE](LICENSE). XFCE, xrdp, Plank, Firefox and the distro packages keep their own licenses. The wallpaper is generated by `assets/src/generate_wallpaper.py` in this repository and released under the same MIT license.
