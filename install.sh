#!/usr/bin/env bash
# ============================================================================
# CloudDesk-RDP installer
# ----------------------------------------------------------------------------
# Turns a minimal Debian/Ubuntu cloud VPS into a lightweight remote desktop:
#   xrdp + xorgxrdp  -> native RDP access on TCP 3389
#   XFCE core        -> light desktop (no bloat suite)
#   Firefox          -> primary browser (distro-appropriate install method)
#   Thunar           -> file manager
#   xfce4-terminal   -> terminal
#   nano (tuned)     -> lightweight editor with syntax highlighting
#   plank            -> macOS-inspired dock (Firefox / Terminal / Files)
#
# Design goals: 1 GB RAM / 1 vCPU class VPS, idempotent re-runs, safe backups,
# no hardcoded credentials, clean uninstall via uninstall.sh.
#
# Usage:  sudo ./install.sh [options]      (see --help)
# Docs:   https://github.com/jjkh1673-tech/CloudDesk-RDP/
# ============================================================================

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly SCRIPT_DIR
readonly CLOUDDESK_VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Paths (on the target system)
# ----------------------------------------------------------------------------
readonly ASSETS_DIR="/usr/share/clouddesk"
readonly MANIFEST_DIR="/var/lib/clouddesk"
readonly MANIFEST_FILE="${MANIFEST_DIR}/manifest"
readonly PKG_SNAPSHOT="${MANIFEST_DIR}/packages-before.txt"
readonly BACKUP_ROOT="/var/backups/clouddesk"
readonly LOG_FILE="/var/log/clouddesk-install.log"

# ----------------------------------------------------------------------------
# Installer state (mutated by argument parsing / detection)
# ----------------------------------------------------------------------------
DESK_USER=""
DRY_RUN=0
FORCE_OS=0
NO_SUDO=0
NO_SWAP=0
SWAP_SIZE="2G"
FIREFOX_METHOD=""
FIREFOX_DESKTOP_ID=""
GTK_THEME="Adwaita"
XFWM_THEME=""
BACKUP_DIR=""
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""

# ----------------------------------------------------------------------------
# UI helpers
# ----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""
fi

info() { printf '%s[i]%s %s\n' "${C_B}" "${C_0}" "$*"; }
ok()   { printf '%s[+]%s %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${C_Y}" "${C_0}" "$*"; }
err()  { printf '%s[x]%s %s\n' "${C_R}" "${C_0}" "$*" >&2; }
die()  { err "$*"; exit 1; }

# run <cmd...> : central mutation wrapper. In dry-run mode nothing executes.
run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s %s\n' "${C_Y}" "${C_0}" "$*"
        return 0
    fi
    "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Package management helpers
# ----------------------------------------------------------------------------
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

apt_update_once() {
    if [ "${_APT_UPDATED:-0}" -eq 0 ]; then
        info "Refreshing package index (apt-get update)..."
        run apt-get -y -q update
        _APT_UPDATED=1
    fi
}

install_core_pkg() {
    apt_update_once
    info "Installing required package: $*"
    run apt-get -y -q install --no-install-recommends "$@"
}

install_try_pkg() {   # optional package: absence is a warning, not a failure
    apt_update_once
    if pkg_installed "$1"; then
        ok "Optional package already installed: $1"
        return 0
    fi
    info "Installing optional package: $1"
    if run apt-get -y -q install --no-install-recommends "$1"; then
        ok "Optional package installed: $1"
        return 0
    fi
    warn "Optional package not available on this distro, skipping: $1"
    return 0
}

# ----------------------------------------------------------------------------
# Manifest / backup management (used by uninstall.sh to undo everything)
# ----------------------------------------------------------------------------
manifest_replace() {  # manifest_replace <key> <value...> : one line per key
    local key="$1"; shift
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s manifest: %s=%s\n' "${C_Y}" "${C_0}" "${key}" "$*"
        return 0
    fi
    mkdir -p "${MANIFEST_DIR}"
    touch "${MANIFEST_FILE}"
    # remove any previous line for this key, then append the fresh one
    grep -v "^${key}|" "${MANIFEST_FILE}" > "${MANIFEST_FILE}.tmp" 2>/dev/null || true
    printf '%s|%s\n' "${key}" "$*" >> "${MANIFEST_FILE}.tmp"
    mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"
}

manifest_get() {  # manifest_get <key> -> prints value or empty
    local key="$1"
    [ -r "${MANIFEST_FILE}" ] || return 0
    grep "^${key}|" "${MANIFEST_FILE}" | head -n 1 | cut -d'|' -f2-
}

# backup_file <path> : copy the ORIGINAL file aside exactly once.
# Re-runs must not overwrite the original backup with our managed version.
backup_file() {
    local path="$1"
    [ -f "${path}" ] || return 0
    if [ -n "$(manifest_get "backup|${path}")" ]; then
        return 0   # original already preserved by an earlier run
    fi
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s backup %s\n' "${C_Y}" "${C_0}" "${path}"
        return 0
    fi
    mkdir -p "${BACKUP_DIR}/$(dirname "${path}")"
    cp -a "${path}" "${BACKUP_DIR}/${path}"
    manifest_replace "backup|${path}" "${BACKUP_DIR}/${path}"
}

# write_config <src> <dest> <mode> : idempotent managed-file install.
# Records "created"/"modified" in the manifest so uninstall.sh can undo it.
write_config() {
    local src="$1" dest="$2" mode="$3" kind
    if [ ! -r "${src}" ]; then
        die "Internal error: missing config source ${src}"
    fi
    if [ -e "${dest}" ]; then
        if cmp -s "${src}" "${dest}"; then
            ok "Already installed (unchanged): ${dest}"
            manifest_replace "file" "${dest}"
            return 0
        fi
        kind="modified"
        backup_file "${dest}"
    else
        kind="created"
    fi
    info "Writing ${dest} (${kind})"
    run install -D -m "${mode}" "${src}" "${dest}"
    manifest_replace "file" "${dest}"
}

# ----------------------------------------------------------------------------
# OS / hardware detection
# ----------------------------------------------------------------------------
detect_os() {
    local rel="${CLOUDDESK_OS_RELEASE:-/etc/os-release}"
    if [ ! -r "${rel}" ]; then
        die "Cannot read OS information (${rel}). This installer supports Debian 12/13 and Ubuntu 22.04/24.04."
    fi
    OS_ID="$( . "${rel}" 2>/dev/null; printf '%s' "${ID:-}" )"
    OS_VERSION_ID="$( . "${rel}" 2>/dev/null; printf '%s' "${VERSION_ID:-}" )"
    OS_CODENAME="$( . "${rel}" 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}" )"

    case "${OS_ID}" in
        debian)
            case "${OS_VERSION_ID}" in
                12|13)
                    FIREFOX_METHOD="esr-apt"
                    ;;
                11)
                    warn "Debian 11 (bullseye) has reached end of LTS (Aug 2026)."
                    FIREFOX_METHOD="esr-apt"
                    ;;
                *)
                    os_unsupported
                    ;;
            esac
            ;;
        ubuntu)
            case "${OS_VERSION_ID}" in
                20.04)
                    warn "Ubuntu 20.04 is past standard support. Consider 22.04/24.04."
                    FIREFOX_METHOD="firefox-apt"
                    ;;
                22.04|24.04)
                    FIREFOX_METHOD="mozilla-repo"
                    ;;
                *)
                    os_unsupported
                    ;;
            esac
            ;;
        *)
            os_unsupported
            ;;
    esac

    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|aarch64) ;;
        *)
            die "Unsupported CPU architecture: ${arch}. Supported: x86_64, aarch64."
            ;;
    esac

    ok "Detected ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME:-unknown}), ${arch} — Firefox method: ${FIREFOX_METHOD}"
}

os_unsupported() {
    if [ "${FORCE_OS}" -eq 1 ]; then
        warn "Proceeding on UNSUPPORTED distro (${OS_ID} ${OS_VERSION_ID}) due to --force-os."
        # Best-effort firefox method guess.
        case "${OS_ID}" in
            debian|raspbian|mx|devuan) FIREFOX_METHOD="esr-apt" ;;
            *) FIREFOX_METHOD="mozilla-repo" ;;
        esac
        return 0
    fi
    cat >&2 <<EOF

This installer officially supports:
    Debian 12 (bookworm), Debian 13 (trixie)
    Ubuntu 22.04 (jammy), Ubuntu 24.04 (noble)
Detected: ${OS_ID} ${OS_VERSION_ID}

Derivatives often work, but are untested. To proceed anyway:
    sudo ./${SCRIPT_NAME} --force-os
EOF
    exit 1
}

core_package_list() {
    # Deliberately minimal. NOT included on purpose: full xfce4 meta package,
    # LibreOffice, media suites, mail clients, games, thumbnailer daemons,
    # screensavers, power managers, databases, snapd.
    echo "xrdp xorgxrdp xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings \
thunar xfce4-terminal dbus-x11 gvfs nano less htop curl ca-certificates iproute2 \
sudo zip unzip fonts-dejavu-core fonts-liberation adwaita-icon-theme"
}

optional_package_list() {
    # Installed one-by-one; missing ones are skipped with a warning.
    echo "plank greybird-gtk-theme xarchiver thunar-archive-plugin lxpolkit xterm"
}

check_network() {
    local host
    case "${OS_ID}" in
        debian) host="https://deb.debian.org" ;;
        ubuntu) host="http://archive.ubuntu.com" ;;
        *)      host="https://deb.debian.org" ;;
    esac
    info "Checking network access to ${host} ..."
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s network check skipped\n' "${C_Y}" "${C_0}"
        return 0
    fi
    if ! curl -fsSI --max-time 15 "${host}" >/dev/null 2>&1; then
        die "No network access to ${host}. Check DNS/connectivity, then re-run."
    fi
    ok "Network is reachable."
}

# ----------------------------------------------------------------------------
# Firefox installation (distro-appropriate, snap avoided where possible)
# ----------------------------------------------------------------------------
install_firefox() {
    apt_update_once
    case "${FIREFOX_METHOD}" in
        esr-apt)
            install_core_pkg firefox-esr
            FIREFOX_DESKTOP_ID="firefox-esr.desktop"
            ;;
        firefox-apt)
            install_core_pkg firefox
            FIREFOX_DESKTOP_ID="firefox.desktop"
            ;;
        mozilla-repo)
            if setup_mozilla_repo; then
                install_core_pkg firefox
                FIREFOX_DESKTOP_ID="firefox.desktop"
            else
                warn "Could not configure the official Mozilla repository."
                warn "Falling back to distro 'firefox' package (on Ubuntu 22.04/24.04 this is a snap transition package and uses more RAM)."
                install_core_pkg firefox || warn "Firefox could not be installed automatically — install manually (see README, Extra Applications)."
                FIREFOX_DESKTOP_ID="firefox.desktop"
            fi
            ;;
        *)
            die "Internal error: unknown firefox method '${FIREFOX_METHOD}'"
            ;;
    esac

    # Resolve the actual desktop-file id (robustness for PPA/derivative setups).
    if [ -f "/usr/share/applications/${FIREFOX_DESKTOP_ID}" ]; then
        :
    elif [ -f /usr/share/applications/firefox.desktop ]; then
        FIREFOX_DESKTOP_ID="firefox.desktop"
    elif [ -f /usr/share/applications/firefox-esr.desktop ]; then
        FIREFOX_DESKTOP_ID="firefox-esr.desktop"
    else
        warn "No Firefox .desktop file found — browser launcher/dock entry may be missing."
    fi
    ok "Firefox desktop id: ${FIREFOX_DESKTOP_ID:-<none>}"
}

setup_mozilla_repo() {
    info "Configuring the official Mozilla APT repository (real .deb Firefox, no snap)..."
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s configure mozilla apt repo\n' "${C_Y}" "${C_0}"
        return 0
    fi
    install_core_pkg gnupg
    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --max-time 30 https://packages.mozilla.org/apt/repo-signing-key.gpg \
            | gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg; then
        warn "Failed to fetch/convert the Mozilla signing key."
        return 1
    fi
    chmod 644 /etc/apt/keyrings/packages.mozilla.org.gpg
    printf '%s\n' "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    cat > /etc/apt/preferences.d/mozilla <<'EOF'
# Prefer the official Mozilla .deb over the snap transition package.
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    _APT_UPDATED=0   # force index refresh after adding the repo
    return 0
}

configure_firefox_policies() {
    local src="${SCRIPT_DIR}/config/firefox/policies.json"
    info "Applying Firefox policy configuration (telemetry/pocket/animations off)..."
    write_config "${src}" "/etc/firefox/policies/policies.json" "0644"
    if pkg_installed firefox-esr; then
        # Debian's ESR build reads /etc/firefox-esr/policies.
        write_config "${src}" "/etc/firefox-esr/policies/policies.json" "0644"
    fi
}

# ----------------------------------------------------------------------------
# Desktop user account
# ----------------------------------------------------------------------------
valid_username() {
    printf '%s' "$1" | grep -qE '^[a-z_][a-z0-9_-]{0,31}$'
}

# set_user_password : pipe user:password into chpasswd WITHOUT building a
# shell string (safe with special characters; never echoed in dry-run).
set_user_password() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s set password for %s\n' "${C_Y}" "${C_0}" "${DESK_USER}"
        return 0
    fi
    printf '%s:%s\n' "${DESK_USER}" "${DESK_PASSWORD}" | chpasswd
    unset DESK_PASSWORD || true
}

prompt_password() {
    local p1 p2
    while :; do
        printf 'Set a login password for "%s" (input hidden): ' "${DESK_USER}" >&2
        read -rs p1
        printf '\n' >&2
        printf 'Repeat the password: ' >&2
        read -rs p2
        printf '\n' >&2
        if [ "${p1}" != "${p2}" ]; then
            err "Passwords do not match. Try again."
            continue
        fi
        if [ "${#p1}" -lt 8 ]; then
            err "Password too short (minimum 8 characters). Try again."
            continue
        fi
        DESK_PASSWORD="${p1}"
        return 0
    done
}

ensure_user() {
    if ! valid_username "${DESK_USER}"; then
        die "Invalid username '${DESK_USER}' (use lowercase letters, digits, '-', '_')."
    fi

    manifest_replace "user" "${DESK_USER}"

    if id "${DESK_USER}" >/dev/null 2>&1; then
        ok "Desktop user '${DESK_USER}' already exists."
        if [ -n "${DESK_PASSWORD}" ]; then
            warn "A password was provided — applying it to the existing user as requested."
            set_user_password
        fi
    else
        info "Creating desktop user '${DESK_USER}'..."
        run useradd -m -s /bin/bash "${DESK_USER}"
        if [ -z "${DESK_PASSWORD}" ]; then
            if [ -t 0 ]; then
                prompt_password
            else
                die "No password available. Re-run interactively, or export CLOUDDESK_PASSWORD, or use --password-stdin."
            fi
        fi
        set_user_password
        ok "User '${DESK_USER}' created."
    fi

    if [ "${NO_SUDO}" -eq 0 ] && getent group sudo >/dev/null 2>&1 && id "${DESK_USER}" >/dev/null 2>&1; then
        if id -nG "${DESK_USER}" | tr ' ' '\n' | grep -qx sudo; then
            ok "User '${DESK_USER}' is already in the sudo group."
        else
            info "Adding '${DESK_USER}' to the sudo group (use --no-sudo to skip)."
            run usermod -aG sudo "${DESK_USER}"
        fi
    fi
}

user_home_var() {  # sets U_HOME and U_GROUP for $DESK_USER
    U_HOME="$(getent passwd "${DESK_USER}" | cut -d: -f6)"
    U_GROUP="$(id -gn "${DESK_USER}")"
    [ -n "${U_HOME}" ] || die "Cannot resolve home directory of user '${DESK_USER}'."
}

# ----------------------------------------------------------------------------
# Nano (lightweight editor) — managed block in /etc/nanorc
# ----------------------------------------------------------------------------
configure_nano() {
    local nanorc="/etc/nanorc"
    local block_src="${SCRIPT_DIR}/config/nano/nanorc.block"
    local tmp extras nano_major=0 nano_minor=0

    nano_version || true
    nano_major="${NANO_MAJOR:-0}"
    nano_minor="${NANO_MINOR:-0}"

    # Version-conditional options:
    #   >= 5.0 : 'set indicator' (mini scrollbar) exists; 'set nowrap' was removed
    #   <  5.0 : 'set nowrap' still needed to avoid hard-wrapping code lines
    extras=""
    if [ "${nano_major}" -ge 5 ]; then
        extras="set indicator"
    else
        extras="set nowrap"
    fi
    info "Detected nano ${nano_major}.${nano_minor} — applying compatible options."

    tmp="$(mktemp)"
    sed "s/^# __NANO_EXTRAS__$/${extras}/" "${block_src}" > "${tmp}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s managed nano block -> %s\n' "${C_Y}" "${C_0}" "${nanorc}"
        rm -f "${tmp}"
        manifest_replace "block" "${nanorc}"
        return 0
    fi

    backup_file "${nanorc}"
    # Remove any previous managed block, then append the fresh one.
    if [ -f "${nanorc}" ]; then
        awk 'BEGIN{skip=0}
             /^# >>> CloudDesk-RDP nano configuration >>>/{skip=1; next}
             /^# <<< CloudDesk-RDP nano configuration <<</{skip=0; next}
             skip==0{print}' "${nanorc}" > "${nanorc}.clouddesk.tmp"
        cat "${nanorc}.clouddesk.tmp" "${tmp}" > "${nanorc}"
        rm -f "${nanorc}.clouddesk.tmp"
    else
        cp "${tmp}" "${nanorc}"
    fi
    chmod 644 "${nanorc}"
    rm -f "${tmp}"
    manifest_replace "block" "${nanorc}"
    ok "Nano configured (line numbers, 4-space tabs, mouse, syntax highlighting)."
}

nano_version() {
    local out
    if [ -n "${NANO_VERSION_OVERRIDE:-}" ]; then
        out="${NANO_VERSION_OVERRIDE}"   # used by tests/unit-tests.sh
    else
        out="$(nano --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
    fi
    NANO_MAJOR="${out%%.*}"
    NANO_MINOR="${out#*.}"
    NANO_MAJOR="${NANO_MAJOR:-0}"
    NANO_MINOR="${NANO_MINOR:-0}"
}

# ----------------------------------------------------------------------------
# XFCE desktop configuration (per-user + /etc/skel for future users)
# ----------------------------------------------------------------------------
deploy_xfce_user_config() {
    local target_root="$1"   # a user home dir, or /etc/skel
    local conf_dir="${target_root}/.config/xfce4/xfconf/xfce-perchannel-xml"
    local tmpdir tmpf

    tmpdir="$(mktemp -d)"

    # xsettings: substitute the GTK theme that actually exists.
    tmpf="${tmpdir}/xsettings.xml"
    sed "s/__GTK_THEME__/${GTK_THEME}/" "${SCRIPT_DIR}/config/xfce4/xsettings.xml" > "${tmpf}"

    # xfwm4: match the GTK theme when its window-manager theme is available.
    sed "s/__XFWM_THEME__/${XFWM_THEME}/" "${SCRIPT_DIR}/config/xfce4/xfwm4.xml" > "${tmpdir}/xfwm4.xml"

    # xfce4-desktop: substitute wallpaper path.
    sed "s|__WALLPAPER__|${ASSETS_DIR}/wallpaper.png|g" \
        "${SCRIPT_DIR}/config/xfce4/xfce4-desktop.xml" > "${tmpdir}/xfce4-desktop.xml"

    cp "${SCRIPT_DIR}/config/xfce4/xfce4-panel.xml" "${tmpdir}/"

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s xfce config -> %s\n' "${C_Y}" "${C_0}" "${conf_dir}"
        rm -rf "${tmpdir}"
        return 0
    fi

    mkdir -p "${conf_dir}"
    install -m 0644 "${tmpdir}/xsettings.xml"      "${conf_dir}/xsettings.xml"
    install -m 0644 "${tmpdir}/xfce4-desktop.xml"  "${conf_dir}/xfce4-desktop.xml"
    install -m 0644 "${tmpdir}/xfce4-panel.xml"    "${conf_dir}/xfce4-panel.xml"
    install -m 0644 "${tmpdir}/xfwm4.xml"          "${conf_dir}/xfwm4.xml"
    rm -rf "${tmpdir}"
}

deploy_plank_user_config() {
    local target_root="$1"
    local dock_dir="${target_root}/.config/plank/dock1"
    local launchers_dir="${dock_dir}/launchers"
    local tmpf id

    if ! pkg_installed plank; then
        warn "plank is not installed — skipping dock configuration (panel still provides launchers)."
        return 0
    fi

    tmpf="$(mktemp)"
    sed "s/__FIREFOX_ID__/${FIREFOX_DESKTOP_ID}/g" \
        "${SCRIPT_DIR}/config/plank/settings.template" > "${tmpf}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s plank config -> %s\n' "${C_Y}" "${C_0}" "${dock_dir}"
        rm -f "${tmpf}"
        return 0
    fi

    mkdir -p "${launchers_dir}"
    install -m 0644 "${tmpf}" "${dock_dir}/settings"
    rm -f "${tmpf}"

    for id in "${FIREFOX_DESKTOP_ID}" xfce4-terminal.desktop thunar.desktop; do
        [ -n "${id}" ] || continue
        sed "s/__DESKTOP_ID__/${id}/" "${SCRIPT_DIR}/config/plank/launcher.dockitem.template" \
            > "${launchers_dir}/${id%.desktop}.dockitem"
    done

    # Ensure the dock starts with the session even if the package autostart
    # file is missing.
    if [ ! -f /etc/xdg/autostart/plank.desktop ]; then
        mkdir -p "${target_root}/.config/autostart"
        cat > "${target_root}/.config/autostart/plank.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=CloudDesk Dock
Exec=plank
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
EOF
    fi
}

deploy_desktop_launchers() {
    local target_root="$1"
    local desk_dir="${target_root}/Desktop"

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s desktop launchers -> %s\n' "${C_Y}" "${C_0}" "${desk_dir}"
        return 0
    fi

    mkdir -p "${desk_dir}"
    install -m 0644 "${SCRIPT_DIR}/config/desktop/Files.desktop"     "${desk_dir}/Files.desktop"
    install -m 0644 "${SCRIPT_DIR}/config/desktop/Settings.desktop" "${desk_dir}/Settings.desktop"
    install -m 0644 "${SCRIPT_DIR}/config/desktop/Terminal.desktop" "${desk_dir}/Terminal.desktop"

    # Firefox launcher: reuse the system .desktop (correct exec/icon), rename
    # displayed name to plain "Firefox" for the requested desktop composition.
    if [ -f "/usr/share/applications/${FIREFOX_DESKTOP_ID}" ]; then
        sed 's/^Name=.*/Name=Firefox/' "/usr/share/applications/${FIREFOX_DESKTOP_ID}" \
            > "${desk_dir}/Firefox.desktop"
        chmod 0644 "${desk_dir}/Firefox.desktop"
    fi
}

ensure_user_dirs() {
    local target_root="$1"
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s mkdir Desktop/Downloads/Workspace in %s\n' "${C_Y}" "${C_0}" "${target_root}"
        return 0
    fi
    mkdir -p "${target_root}/Desktop" "${target_root}/Downloads" "${target_root}/Workspace"
}

apply_desktop_to_users() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s deploy xfce/plank/desktop config to %s home and /etc/skel\n' "${C_Y}" "${C_0}" "${DESK_USER}"
        return 0
    fi
    user_home_var
    info "Applying desktop configuration for user '${DESK_USER}' and /etc/skel..."

    deploy_xfce_user_config "${U_HOME}"
    deploy_plank_user_config "${U_HOME}"
    deploy_desktop_launchers "${U_HOME}"
    ensure_user_dirs "${U_HOME}"

    # /etc/skel so any user created later gets the same desktop.
    deploy_xfce_user_config "/etc/skel"
    deploy_plank_user_config "/etc/skel"
    deploy_desktop_launchers "/etc/skel"
    ensure_user_dirs "/etc/skel"

    if [ "${DRY_RUN}" -eq 0 ]; then
        chown -R "${DESK_USER}:${U_GROUP}" \
            "${U_HOME}/.config" "${U_HOME}/Desktop" \
            "${U_HOME}/Downloads" "${U_HOME}/Workspace"
        chmod 755 "${U_HOME}" || true
    fi
    ok "Desktop configuration applied."
}

# ----------------------------------------------------------------------------
# Theme selection (macOS-inspired but stock and light)
# ----------------------------------------------------------------------------
select_theme() {
    if pkg_installed greybird-gtk-theme; then
        GTK_THEME="Greybird"
        XFWM_THEME="Greybird"
    else
        GTK_THEME="Adwaita"
        XFWM_THEME="default"
        warn "greybird-gtk-theme unavailable — using built-in Adwaita theme."
    fi
    ok "GTK theme: ${GTK_THEME}"
}

# ----------------------------------------------------------------------------
# xrdp, polkit, assets
# ----------------------------------------------------------------------------
configure_xrdp() {
    info "Configuring xrdp session launcher..."
    write_config "${SCRIPT_DIR}/config/xrdp/startwm.sh" /etc/xrdp/startwm.sh "0755"

    # Gentle patch of xrdp.ini: touch only known keys; original is backed up.
    local ini="/etc/xrdp/xrdp.ini"
    if [ -f "${ini}" ]; then
        backup_file "${ini}"
        if grep -qE '^max_bpp=' "${ini}"; then
            info "Setting max_bpp=24 (bandwidth-friendly for low-end links)"
            run sed -i 's/^max_bpp=.*/max_bpp=24/' "${ini}"
        fi
        if grep -qE '^ls_title=' "${ini}"; then
            run sed -i 's/^ls_title=.*/ls_title=CloudDesk-RDP/' "${ini}"
        fi
        manifest_replace "file" "${ini}"
    else
        warn "${ini} not found — is the xrdp package installed correctly?"
    fi
}

configure_polkit() {
    info "Installing polkit rules (avoids colord password prompts in RDP sessions)..."
    write_config "${SCRIPT_DIR}/config/polkit/49-clouddesk-colord.rules" \
        /etc/polkit-1/rules.d/49-clouddesk-colord.rules "0644"
    write_config "${SCRIPT_DIR}/config/polkit/49-clouddesk-colord.pkla" \
        /etc/polkit-1/localauthority/50-local.d/49-clouddesk-colord.pkla "0644"
}

configure_assets() {
    info "Installing wallpaper..."
    write_config "${SCRIPT_DIR}/assets/wallpaper.png" "${ASSETS_DIR}/wallpaper.png" "0644"
}

# ----------------------------------------------------------------------------
# Optional swap file (helps 1 GB RAM boxes survive Firefox)
# ----------------------------------------------------------------------------
setup_swap() {
    if [ "${NO_SWAP}" -eq 1 ]; then
        info "Swap setup skipped (--no-swap)."
        return 0
    fi
    if [ -n "$(manifest_get "swapfile")" ]; then
        ok "Swap already configured by CloudDesk (idempotent skip)."
        return 0
    fi

    # Only when the box actually needs it: < 2 GB RAM and no swap active.
    if [ "${DRY_RUN}" -eq 0 ]; then
        if swapon --noheadings --show 2>/dev/null | grep -q .; then
            ok "Swap already active on this system — not adding another."
            return 0
        fi
        local ram_kb
        ram_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 999999999)"
        if [ "${ram_kb}" -ge 2000000 ]; then
            ok "RAM >= 2 GB and no swap shortage expected — swap not added."
            return 0
        fi
    fi

    local size_mb
    case "${SWAP_SIZE}" in
        *[Gg]) size_mb="${SWAP_SIZE%[Gg]}" ;;
        *[Mm]) size_mb="${SWAP_SIZE%[Mm]}" ;;
        *)     size_mb="${SWAP_SIZE}" ;;
    esac
    case "${size_mb}" in
        ''|*[!0-9]*) die "Invalid --swap-size value '${SWAP_SIZE}' (use e.g. 2G or 512M)." ;;
    esac
    case "${SWAP_SIZE}" in
        *[Gg]) size_mb=$(( size_mb * 1024 )) ;;
    esac

    info "Creating ${size_mb} MB swapfile at /swapfile (helps 1 GB RAM machines)..."
    run dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none
    run chmod 600 /swapfile
    run mkswap -f /swapfile
    run swapon /swapfile

    local fstab="/etc/fstab"
    if [ -f "${fstab}" ] && ! grep -q '^/swapfile ' "${fstab}"; then
        backup_file "${fstab}"
        run sh -c "printf '%s\n' '/swapfile none swap sw 0 0' >> '${fstab}'"
    fi
    manifest_replace "swapfile" "/swapfile"
    ok "Swap enabled: $(swapon --noheadings --show 2>/dev/null | head -n1 || echo '/swapfile')"
}

# ----------------------------------------------------------------------------
# Package bookkeeping for uninstall.sh
# ----------------------------------------------------------------------------
# Snapshot what is installed BEFORE we change anything, so uninstall.sh only
# ever removes packages the installer actually introduced.
pre_install_snapshot() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi
    mkdir -p "${MANIFEST_DIR}"
    dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort > "${PKG_SNAPSHOT}" || true
    ok "Recorded pre-install package snapshot (${PKG_SNAPSHOT})."
}

record_new_packages() {
    local all p new=""
    all="$(core_package_list) $(optional_package_list)"
    case "${FIREFOX_METHOD}" in
        esr-apt)      all="${all} firefox-esr" ;;
        mozilla-repo) all="${all} firefox gnupg" ;;
        *)            all="${all} firefox" ;;
    esac
    for p in ${all}; do
        pkg_installed "${p}" || continue
        if [ -f "${PKG_SNAPSHOT}" ] && grep -qxF "${p}" "${PKG_SNAPSHOT}"; then
            continue   # already present before this installer ran
        fi
        new="${new} ${p}"
    done
    manifest_replace "packages" "${new# }"
}

# ----------------------------------------------------------------------------
# Services
# ----------------------------------------------------------------------------
enable_services() {
    if [ -d /run/systemd/system ] && have systemctl; then
        info "Enabling and restarting xrdp services..."
        run systemctl enable xrdp.service xrdp-sesman.service
        run systemctl restart xrdp.service xrdp-sesman.service
    else
        warn "systemd not detected (container environment?)."
        warn "Start services manually after boot with: sudo clouddesk start"
    fi
}

# ----------------------------------------------------------------------------
# Post-install validation
# ----------------------------------------------------------------------------
V_ERR=0
V_WARN=0

vpass() { printf '  %sPASS%s  %s\n' "${C_G}" "${C_0}" "$1"; }
vfail() { printf '  %sFAIL%s  %s\n' "${C_R}" "${C_0}" "$1"; V_ERR=$((V_ERR + 1)); }
vwarn() { printf '  %sWARN%s  %s\n' "${C_Y}" "${C_0}" "$1"; V_WARN=$((V_WARN + 1)); }

vcmd()  { if have "$1"; then vpass "command: $1"; else vfail "command missing: $1"; fi; }
vfile() { if [ "$2" = "-x" ]; then
              if [ -x "$1" ]; then vpass "executable: $1"; else vfail "not executable: $1"; fi
          else
              if [ -r "$1" ]; then vpass "file: $1"; else vfail "missing file: $1"; fi
          fi; }

post_validate() {
    info "Validating installation..."
    echo ""
    if [ "${DRY_RUN}" -eq 1 ]; then
        echo "  (dry-run mode: system validation skipped)"
        return 0
    fi

    echo "Commands:"
    vcmd xrdp
    vcmd xrdp-sesman
    vcmd startxfce4
    vcmd xfwm4
    vcmd xfsettingsd
    vcmd thunar
    vcmd xfce4-terminal
    vcmd nano
    if have firefox || have firefox-esr; then
        vpass "command: firefox (or firefox-esr)"
    else
        vfail "command missing: firefox"
    fi
    if pkg_installed plank; then vpass "package: plank (dock)"; else vwarn "package plank not installed — dock disabled, panel still usable"; fi

    echo "Configuration:"
    vfile /etc/xrdp/startwm.sh -x
    vfile /etc/xrdp/xrdp.ini
    vfile /etc/firefox/policies/policies.json
    vfile "${ASSETS_DIR}/wallpaper.png"
    vfile /usr/local/bin/clouddesk -x

    user_home_var
    vfile "${U_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
    vfile "${U_HOME}/.config/plank/dock1/settings"
    for f in Firefox.desktop Files.desktop Settings.desktop Terminal.desktop; do
        if [ -f "${U_HOME}/Desktop/${f}" ]; then
            vpass "desktop launcher: ${f}"
        else
            vwarn "desktop launcher missing: ${U_HOME}/Desktop/${f}"
        fi
    done

    if [ "${DRY_RUN}" -eq 0 ]; then
        echo "Services:"
        if [ -d /run/systemd/system ] && have systemctl; then
            if systemctl is-enabled xrdp.service >/dev/null 2>&1; then vpass "service enabled: xrdp"; else vfail "service not enabled: xrdp"; fi
            if systemctl is-enabled xrdp-sesman.service >/dev/null 2>&1; then vpass "service enabled: xrdp-sesman"; else vfail "service not enabled: xrdp-sesman"; fi
            if systemctl is-active --quiet xrdp; then vpass "service active: xrdp"; else vfail "service not active: xrdp"; fi
            if systemctl is-active --quiet xrdp-sesman; then vpass "service active: xrdp-sesman"; else vfail "service not active: xrdp-sesman"; fi
        else
            vwarn "no systemd — skipping service checks (start manually: sudo clouddesk start)"
        fi
        if have ss && ss -tln 2>/dev/null | grep -q ':3389 '; then
            vpass "network: TCP 3389 listening"
        else
            vwarn "TCP 3389 not listening yet (service may still be starting; check: sudo clouddesk status)"
        fi
    fi

    echo ""
    if [ "${V_ERR}" -gt 0 ]; then
        err "Validation finished with ${V_ERR} error(s) and ${V_WARN} warning(s)."
        return 1
    fi
    ok "Validation finished: no errors, ${V_WARN} warning(s)."
    return 0
}

# ----------------------------------------------------------------------------
# Final summary (printed at the end of every install)
# ----------------------------------------------------------------------------
print_summary() {
    local ip ip4
    ip4="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "${ip4}" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    else
        ip="${ip4}"
    fi
    [ -n "${ip}" ] || ip="<server-ip>"

    cat <<EOF

${C_G}============================================================${C_0}
 ${C_G}CloudDesk-RDP installation finished${C_0}
${C_G}============================================================${C_0}

 Status        : $([ "${V_ERR}" -eq 0 ] && echo "${C_G}SUCCESS${C_0}" || echo "${C_Y}COMPLETED WITH WARNINGS${C_0}")
 Desktop user  : ${DESK_USER}
 RDP address   : ${ip}:3389   (from any RDP client, e.g. Windows mstsc)

 Useful commands:
   Check status    : clouddesk status
   Restart service : sudo clouddesk restart
   View logs       : clouddesk logs            (sudo clouddesk logs install)

 Files:
   Install log     : ${LOG_FILE}
   Backups         : ${BACKUP_ROOT}/
   Assets          : ${ASSETS_DIR}/

 Firewall reminder (if using ufw):
   sudo ufw allow 3389/tcp

 Uninstall:
   sudo ${SCRIPT_DIR}/uninstall.sh --yes

EOF
}

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
CloudDesk-RDP installer v${CLOUDDESK_VERSION}

Turns a Debian/Ubuntu VPS into a lightweight XFCE desktop reachable via RDP.

Usage:
  sudo ./${SCRIPT_NAME} [options]

Options:
  --user NAME        Desktop login username (default: ${CLOUDDESK_USER:-clouddesk}, or \$CLOUDDESK_USER)
  --password-stdin   Read the new user's password from stdin (automation-safe)
  --no-sudo          Do NOT add the desktop user to the sudo group
  --no-swap          Do not create a swapfile on low-RAM machines
  --swap-size SIZE   Swapfile size, e.g. 2G or 512M (default: 2G)
  --force-os         Proceed on an unsupported distro (best effort)
  --dry-run          Print planned actions without changing the system
  -h, --help         This help
  -V, --version      Print version

Environment:
  CLOUDDESK_USER       Default username if --user is not given
  CLOUDDESK_PASSWORD   Non-interactive password (prefer --password-stdin)

Examples:
  sudo ./${SCRIPT_NAME}
  echo 'S3cret!Pass' | sudo ./${SCRIPT_NAME} --user desk --password-stdin
EOF
}

parse_args() {
    DESK_USER="${CLOUDDESK_USER:-clouddesk}"
    DESK_PASSWORD="${CLOUDDESK_PASSWORD:-}"
    if [ -n "${CLOUDDESK_PASSWORD:-}" ]; then
        warn "CLOUDDESK_PASSWORD is set via environment — consider --password-stdin instead (keeps secrets out of shell history)."
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user)
                [ $# -ge 2 ] || die "--user requires a value"
                DESK_USER="$2"; shift 2 ;;
            --password-stdin)
                warn "Reading password from stdin (--password-stdin)..."
                IFS= read -r DESK_PASSWORD
                shift
                ;;
            --no-sudo)   NO_SUDO=1;   shift ;;
            --no-swap)   NO_SWAP=1;   shift ;;
            --swap-size)
                [ $# -ge 2 ] || die "--swap-size requires a value"
                SWAP_SIZE="$2"; shift 2 ;;
            --force-os)  FORCE_OS=1;  shift ;;
            --dry-run)   DRY_RUN=1;   shift ;;
            -h|--help)   usage; exit 0 ;;
            -V|--version) echo "CloudDesk-RDP ${CLOUDDESK_VERSION}"; exit 0 ;;
            *)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

banner() {
    cat <<EOF

${C_B}  ==========================================================
   CloudDesk-RDP  v${CLOUDDESK_VERSION}
   Lightweight XFCE + xrdp desktop for 1 GB RAM cloud VPS
  ==========================================================${C_0}

EOF
}

install_helper_cli() {
    info "Installing clouddesk helper CLI..."
    write_config "${SCRIPT_DIR}/bin/clouddesk" /usr/local/bin/clouddesk "0755"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    banner

    trap 'err "Installer failed at line $LINENO. Review the output above; fix the issue and safely re-run this installer."' ERR

    if [ "$(id -u)" -ne 0 ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
            warn "Running as non-root in dry-run mode — system checks are limited."
        else
            die "Please run as root: sudo ./${SCRIPT_NAME}"
        fi
    fi

    if [ "${DRY_RUN}" -eq 0 ]; then
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        exec > >(tee -a "${LOG_FILE}") 2>&1
        export DEBIAN_FRONTEND=noninteractive
    fi
    _APT_UPDATED=0
    BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

    info "Install log: ${LOG_FILE} (dry-run: $([ "${DRY_RUN}" -eq 1 ] && echo yes || echo no))"

    detect_os
    check_network

    info "Installing core packages (minimal XFCE + xrdp stack)..."
    pre_install_snapshot
    # shellcheck disable=SC2046
    install_core_pkg $(core_package_list)

    local p
    for p in $(optional_package_list); do
        install_try_pkg "${p}"
    done

    install_firefox
    record_new_packages
    select_theme
    ensure_user
    install_helper_cli
    configure_assets
    configure_xrdp
    configure_polkit
    configure_firefox_policies
    configure_nano
    apply_desktop_to_users
    enable_services
    setup_swap

    if post_validate; then
        print_summary
    else
        print_summary
        die "Installation completed with errors — review the validation output above."
    fi
}

# Source-safe: allows tests/unit-tests.sh to import functions without running.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
