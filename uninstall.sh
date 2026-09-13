#!/usr/bin/env bash
# ============================================================================
# CloudDesk-RDP uninstaller
# ----------------------------------------------------------------------------
# Reverts what install.sh changed, guided by the manifest written during
# installation (/var/lib/clouddesk/manifest):
#   - stops and disables the xrdp services
#   - restores every backed-up system file to its original content
#   - deletes files the installer created
#   - removes the managed nano block from /etc/nanorc
#   - removes the swapfile and its /etc/fstab entry (if we added them)
#   - optionally purges the packages the installer introduced (default: ask)
#   - keeps user data and the desktop user unless --remove-user is given
#
# Usage:  sudo ./uninstall.sh [--yes] [--keep-packages] [--remove-user]
# ============================================================================

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly MANIFEST_DIR="/var/lib/clouddesk"
readonly MANIFEST_FILE="${MANIFEST_DIR}/manifest"
readonly ASSETS_DIR="/usr/share/clouddesk"
readonly CLI_PATH="/usr/local/bin/clouddesk"
readonly NANO_BLOCK_START="# >>> CloudDesk-RDP nano configuration >>>"
readonly NANO_BLOCK_END="# <<< CloudDesk-RDP nano configuration <<<"

ASSUME_YES=0
KEEP_PACKAGES=0
REMOVE_USER=0
DRY_RUN=0

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

run() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s %s\n' "${C_Y}" "${C_0}" "$*"
        return 0
    fi
    "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    if [ "${ASSUME_YES}" -eq 1 ] || [ "${DRY_RUN}" -eq 1 ]; then
        return 0
    fi
    local reply
    printf '%s [y/N]: ' "$1" >&2
    read -r reply
    case "${reply}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------------
# Manifest helpers (same format as install.sh)
# ----------------------------------------------------------------------------
manifest_keys() {  # print all lines starting with the given key type
    local prefix="$1"
    [ -r "${MANIFEST_FILE}" ] || return 0
    grep "^${prefix}|" "${MANIFEST_FILE}" || true
}

manifest_get() {
    local key="$1"
    [ -r "${MANIFEST_FILE}" ] || return 0
    grep "^${key}|" "${MANIFEST_FILE}" | head -n 1 | cut -d'|' -f2-
}

# ----------------------------------------------------------------------------
# Uninstall steps
# ----------------------------------------------------------------------------
stop_services() {
    info "Stopping and disabling xrdp services..."
    if [ -d /run/systemd/system ] && have systemctl; then
        run systemctl disable --now xrdp.service xrdp-sesman.service 2>/dev/null || true
    else
        run pkill -x xrdp 2>/dev/null || true
        run pkill -x xrdp-sesman 2>/dev/null || true
    fi
    ok "Services stopped."
}

remove_swap() {
    local swap
    swap="$(manifest_get "swapfile")"
    [ -n "${swap}" ] || return 0
    info "Removing swapfile ${swap}..."
    run swapoff "${swap}" 2>/dev/null || true
    run rm -f "${swap}"
    local fstab="/etc/fstab"
    if [ -f "${fstab}" ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
            printf '%s[dry-run]%s remove swap line from %s\n' "${C_Y}" "${C_0}" "${fstab}"
        else
            sed -i '\|^'"${swap}"' |d' "${fstab}"
        fi
    fi
    ok "Swap removed."
}

restore_or_remove_files() {
    info "Restoring backups / removing managed files..."
    local path backup

    # Restore every file for which an original backup exists.
    while IFS='|' read -r _ path backup; do
        [ -n "${path}" ] || continue
        if [ "${DRY_RUN}" -eq 1 ]; then
            printf '%s[dry-run]%s restore %s\n' "${C_Y}" "${C_0}" "${path}"
        elif [ -f "${backup}" ]; then
            mkdir -p "$(dirname "${path}")"
            cp -a "${backup}" "${path}"
            ok "Restored original: ${path}"
        else
            warn "Backup missing for ${path} — left as-is."
        fi
    done < <(manifest_keys "backup")

    # Delete files we created outright (no backup == we created them).
    while IFS='|' read -r _ path; do
        [ -n "${path}" ] || continue
        if [ -n "$(manifest_get "backup|${path}")" ]; then
            continue   # handled above (restored)
        fi
        if [ -e "${path}" ]; then
            run rm -f "${path}"
            ok "Removed managed file: ${path}"
        fi
    done < <(manifest_keys "file")
}

remove_nano_block() {
    local nanorc
    nanorc="$(manifest_get "block")"
    [ -n "${nanorc}" ] || nanorc="/etc/nanorc"
    [ -f "${nanorc}" ] || return 0
    info "Removing managed nano block from ${nanorc}..."
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s strip block from %s\n' "${C_Y}" "${C_0}" "${nanorc}"
        return 0
    fi
    awk -v start="${NANO_BLOCK_START}" -v end="${NANO_BLOCK_END}" \
        'index($0, start){skip=1; next} index($0, end){skip=0; next} skip==0{print}' \
        "${nanorc}" > "${nanorc}.tmp"
    mv "${nanorc}.tmp" "${nanorc}"
    chmod 644 "${nanorc}"
    ok "Nano block removed."
}

purge_packages() {
    local packages
    packages="$(manifest_get "packages")"
    if [ "${KEEP_PACKAGES}" -eq 1 ]; then
        info "Keeping installed packages (--keep-packages)."
        return 0
    fi
    if [ -z "${packages}" ]; then
        info "No package list in manifest — nothing to purge."
        return 0
    fi
    echo ""
    info "The installer introduced these packages:"
    echo "    ${packages}"
    echo ""
    if ! confirm "Remove these packages now? (user data is NOT touched)"; then
        info "Packages kept. Remove later with: sudo apt-get purge ${packages}"
        return 0
    fi
    info "Purging packages..."
    # shellcheck disable=SC2086  # intentional word splitting: apt takes a package list
    run apt-get -y -q purge ${packages}
    run apt-get -y -q autoremove
    ok "Packages removed."
}

remove_mozilla_repo_files() {
    # Only remove if the files carry our markers (never touch foreign configs).
    local list="/etc/apt/sources.list.d/mozilla.list"
    local pin="/etc/apt/preferences.d/mozilla"
    local key="/etc/apt/keyrings/packages.mozilla.org.gpg"
    local removed=0
    if [ -f "${pin}" ] && grep -q "snap transition package" "${pin}" 2>/dev/null; then
        run rm -f "${pin}"; removed=1
    fi
    if [ -f "${list}" ] && grep -q "packages.mozilla.org/apt mozilla main" "${list}" 2>/dev/null; then
        run rm -f "${list}"; removed=1
    fi
    if [ "${removed}" -eq 1 ]; then
        run rm -f "${key}"
        ok "Mozilla APT repository configuration removed."
    fi
}

remove_user_account() {
    local user
    user="$(manifest_get "user")"
    [ -n "${user}" ] || return 0
    if [ "${REMOVE_USER}" -eq 0 ]; then
        info "Desktop user '${user}' and all data kept. Remove with: sudo userdel -r ${user}"
        return 0
    fi
    if ! id "${user}" >/dev/null 2>&1; then
        return 0
    fi
    warn "About to DELETE user '${user}' AND the home directory (irreversible)."
    if confirm "Delete user '${user}' and /home files?"; then
        run pkill -u "${user}" 2>/dev/null || true
        sleep 1
        run userdel -r "${user}" 2>/dev/null || run userdel "${user}" || true
        ok "User '${user}' removed."
    fi
}

remove_leftovers() {
    info "Removing remaining CloudDesk components..."
    if [ -d "${ASSETS_DIR}" ]; then
        run rm -rf "${ASSETS_DIR}"
        ok "Removed ${ASSETS_DIR}"
    fi
    if [ -e "${CLI_PATH}" ]; then
        run rm -f "${CLI_PATH}"
        ok "Removed ${CLI_PATH}"
    fi
    remove_mozilla_repo_files
    # Manifest removal must be last (dry-run keeps it for a later real run).
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '%s[dry-run]%s rm -rf %s\n' "${C_Y}" "${C_0}" "${MANIFEST_DIR}"
    else
        rm -rf "${MANIFEST_DIR}"
        ok "Removed ${MANIFEST_DIR}"
    fi
    warn "Install backups are preserved in /var/backups/clouddesk/ (delete manually when confident)."
}

print_summary() {
    cat <<EOF

${C_G}CloudDesk-RDP uninstall finished.${C_0}
 - xrdp services stopped/disabled
 - system configuration restored or removed
 - packages: $([ "${KEEP_PACKAGES}" -eq 1 ] && echo "kept (--keep-packages)" || echo "purged per manifest (unless you declined)")
 - desktop user: $([ "${REMOVE_USER}" -eq 1 ] && echo "removed" || echo "kept")
 - backups preserved in /var/backups/clouddesk/

If you ever want the desktop back, just run install.sh again.
EOF
}

usage() {
    cat <<EOF
CloudDesk-RDP uninstaller

Usage:
  sudo ./${SCRIPT_NAME} [options]

Options:
  -y, --yes          Non-interactive: assume yes for all confirmations
  --keep-packages    Do NOT purge the packages introduced by install.sh
  --remove-user      Also delete the desktop user and its home directory
  --dry-run          Show what would happen without changing anything
  -h, --help         This help
  -V, --version      Print version
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes)         ASSUME_YES=1; shift ;;
            --keep-packages)  KEEP_PACKAGES=1; shift ;;
            --remove-user)    REMOVE_USER=1; shift ;;
            --dry-run)        DRY_RUN=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            -V|--version)     echo "CloudDesk-RDP uninstaller 1.0.0"; exit 0 ;;
            *)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [ "$(id -u)" -ne 0 ] && [ "${DRY_RUN}" -eq 0 ]; then
        die "Please run as root: sudo ./${SCRIPT_NAME}"
    fi

    info "CloudDesk-RDP uninstaller (dry-run: $([ "${DRY_RUN}" -eq 1 ] && echo yes || echo no))"
    if [ ! -r "${MANIFEST_FILE}" ]; then
        warn "No manifest found at ${MANIFEST_FILE}."
        warn "Either CloudDesk-RDP is not installed, or it was already uninstalled."
        info "Performing best-effort cleanup of standard paths only."
    fi

    stop_services
    remove_swap
    restore_or_remove_files
    remove_nano_block
    purge_packages
    remove_leftovers
    remove_user_account
    print_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
