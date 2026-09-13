#!/usr/bin/env bash
# ============================================================================
# CloudDesk-RDP unit tests — function-level checks without touching the system
# ----------------------------------------------------------------------------
# Sources install.sh (source-safe: main() only runs when executed directly)
# and exercises OS detection, argument parsing, package lists, validation
# helpers and template substitution logic against synthetic /etc/os-release
# files.
#
# Run:  ./tests/unit-tests.sh          (no root required)
# ============================================================================

set -o nounset
set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

PASS=0
FAIL=0
CURRENT=""

setup() {
    # Source the installer: defines functions and constants, runs no main().
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/install.sh" >/dev/null 2>&1 || {
        echo "FATAL: could not source install.sh" >&2
        exit 1
    }
    TMPDIR_TEST="$(mktemp -d)"
}

teardown() {
    rm -rf "${TMPDIR_TEST:-/nonexistent}"
    unset CLOUDDESK_OS_RELEASE || true
}

tbegin() { CURRENT="$1"; }
tpass()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "${CURRENT}"; }
tfail()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s  (%s)\n' "${CURRENT}" "$1"; }

assert_eq() {  # assert_eq <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then tpass; else tfail "$1: expected [$2] got [$3]"; fi
}

assert_rc() {  # assert_rc <desc> <expected_rc> <command...>
    local want="$2"; shift 2
    local got=0
    ( "$@" ) >/dev/null 2>&1 || got=$?
    if [ "${got}" -eq "${want}" ]; then tpass; else tfail "$1: expected rc=${want} got rc=${got}"; fi
}

write_os_release() {  # write_os_release <id> <version_id>
    cat > "${TMPDIR_TEST}/os-release" <<EOF
ID="$1"
VERSION_ID="$2"
VERSION_CODENAME="testcodename"
PRETTY_NAME="$1 $2 test"
EOF
    export CLOUDDESK_OS_RELEASE="${TMPDIR_TEST}/os-release"
}

# ----------------------------------------------------------------------------
setup
DRY_RUN=1          # global safety: functions must never mutate anything here
# NO_COLOR is consumed by install.sh's color setup when sourced below.
export NO_COLOR=1

echo "== OS detection =="
tbegin "debian 12 -> firefox-esr from apt"
write_os_release debian 12
DESK_USER="" ; FIREFOX_METHOD="" ; FORCE_OS=0
detect_os
assert_eq "method" "esr-apt" "${FIREFOX_METHOD}"

tbegin "debian 13 -> firefox-esr from apt"
write_os_release debian 13
detect_os
assert_eq "method" "esr-apt" "${FIREFOX_METHOD}"

tbegin "ubuntu 22.04 -> mozilla repo"
write_os_release ubuntu 22.04
detect_os
assert_eq "method" "mozilla-repo" "${FIREFOX_METHOD}"

tbegin "ubuntu 24.04 -> mozilla repo"
write_os_release ubuntu 24.04
detect_os
assert_eq "method" "mozilla-repo" "${FIREFOX_METHOD}"

tbegin "ubuntu 20.04 -> firefox deb from apt"
write_os_release ubuntu 20.04
detect_os
assert_eq "method" "firefox-apt" "${FIREFOX_METHOD}"

tbegin "unsupported distro refused (centos 7)"
write_os_release centos 7
FORCE_OS=0
assert_rc "detect_os must exit 1" 1 detect_os

tbegin "unsupported distro proceeds with --force-os"
FORCE_OS=1
detect_os
assert_eq "force method guess" "mozilla-repo" "${FIREFOX_METHOD}"
FORCE_OS=0

echo "== Username validation =="
tbegin "valid usernames"
if valid_username "clouddesk" && valid_username "a" && valid_username "user_2" && valid_username "dev-ops"; then tpass; else tfail "valid names rejected"; fi

tbegin "invalid usernames rejected"
if valid_username "CloudDesk" || valid_username "1abc" || valid_username "user name" || valid_username "" || valid_username "user;id"; then tfail "invalid name accepted"; else tpass; fi

echo "== Argument parsing =="
tbegin "parse_args: --user"
DESK_USER=""
parse_args --user testuser
assert_eq "user set" "testuser" "${DESK_USER}"

tbegin "parse_args: flags"
NO_SWAP=0; DRY_RUN=0; NO_SUDO=0; FORCE_OS=0
parse_args --no-swap --dry-run --no-sudo --force-os
assert_eq "NO_SWAP"  "1" "${NO_SWAP}"
assert_eq "DRY_RUN"  "1" "${DRY_RUN}"
assert_eq "NO_SUDO"  "1" "${NO_SUDO}"
assert_eq "FORCE_OS" "1" "${FORCE_OS}"

tbegin "parse_args: env default user"
DESK_USER=""
CLOUDDESK_USER=envuser parse_args
assert_eq "env user" "envuser" "${DESK_USER}"

tbegin "parse_args: unknown option fails"
assert_rc "unknown option" 1 parse_args --frobnicate

tbegin "parse_args: --password-stdin reads stdin"
DESK_PASSWORD=""
DESK_PASSWORD="$(printf 'topsecret123\n' | (parse_args --password-stdin >/dev/null 2>&1; printf '%s' "${DESK_PASSWORD:-}"))"
assert_eq "password read" "topsecret123" "${DESK_PASSWORD}"

echo "== Swap size validation (dry-run) =="
tbegin "setup_swap accepts 2G"
NO_SWAP=0
DRY_RUN=1
assert_rc "2G accepted" 0 setup_swap

tbegin "setup_swap rejects garbage size"
SWAP_SIZE="banana"
assert_rc "garbage rejected" 1 setup_swap

tbegin "setup_swap rejects abcM"
SWAP_SIZE="abcM"
assert_rc "abcM rejected" 1 setup_swap

tbegin "setup_swap --no-swap skips"
# SWAP_SIZE/NO_SWAP are consumed by the sourced install.sh's setup_swap().
# shellcheck disable=SC2034
SWAP_SIZE="2G"; NO_SWAP=1
assert_rc "no-swap ok" 0 setup_swap
NO_SWAP=0

echo "== Nano version logic =="
tbegin "nano >= 5 gets indicator"
# NANO_VERSION_OVERRIDE is consumed by install.sh's nano_version() (sourced above).
# shellcheck disable=SC2034
NANO_VERSION_OVERRIDE="7.2"
nano_version
assert_eq "major" "7" "${NANO_MAJOR}"
assert_eq "minor" "2" "${NANO_MINOR}"

tbegin "nano < 5 branch"
# shellcheck disable=SC2034
NANO_VERSION_OVERRIDE="4.8"
nano_version
assert_eq "major" "4" "${NANO_MAJOR}"

echo "== Package lists =="
tbegin "core list contains required stack"
local_list="$(core_package_list)"
for p in xrdp xorgxrdp xfce4-session xfwm4 xfdesktop4 thunar xfce4-terminal nano gvfs; do
    case " ${local_list} " in
        *" ${p} "*) ;;
        *) tfail "core list missing ${p}"; break ;;
    esac
done
tpass

tbegin "core list excludes banned heavy packages"
for bad in "xfce4 " libreoffice snapd gimp vlc thunderbird; do
    if printf '%s' "${local_list}" | grep -qw "${bad}"; then
        tfail "banned package present: ${bad}"
        break
    fi
done
tpass

echo "== Template substitution =="
tbegin "xsettings theme substitution"
GTK_THEME="Greybird"
sed "s/__GTK_THEME__/${GTK_THEME}/" "${PROJECT_DIR}/config/xfce4/xsettings.xml" > "${TMPDIR_TEST}/xsettings.xml"
if grep -q "Greybird" "${TMPDIR_TEST}/xsettings.xml" && ! grep -q "__GTK_THEME__" "${TMPDIR_TEST}/xsettings.xml"; then tpass; else tfail "theme placeholder not substituted"; fi

tbegin "wallpaper substitution"
sed "s|__WALLPAPER__|/usr/share/clouddesk/wallpaper.png|g" "${PROJECT_DIR}/config/xfce4/xfce4-desktop.xml" > "${TMPDIR_TEST}/xfce4-desktop.xml"
if ! grep -q "__WALLPAPER__" "${TMPDIR_TEST}/xfce4-desktop.xml" && grep -q "/usr/share/clouddesk/wallpaper.png" "${TMPDIR_TEST}/xfce4-desktop.xml"; then tpass; else tfail "wallpaper placeholder not substituted"; fi

tbegin "plank settings substitution"
FIREFOX_DESKTOP_ID="firefox-esr.desktop"
sed "s/__FIREFOX_ID__/${FIREFOX_DESKTOP_ID}/g" "${PROJECT_DIR}/config/plank/settings.template" > "${TMPDIR_TEST}/settings"
if ! grep -q "__FIREFOX_ID__" "${TMPDIR_TEST}/settings" && grep -q "firefox-esr.desktop.dockitem" "${TMPDIR_TEST}/settings"; then tpass; else tfail "plank placeholder not substituted"; fi

tbegin "nano block extras substitution"
sed "s/^# __NANO_EXTRAS__$/set indicator/" "${PROJECT_DIR}/config/nano/nanorc.block" > "${TMPDIR_TEST}/nanorc.block"
if ! grep -q "__NANO_EXTRAS__" "${TMPDIR_TEST}/nanorc.block" && grep -q "^set indicator$" "${TMPDIR_TEST}/nanorc.block"; then tpass; else tfail "nano extras not substituted"; fi

echo "== Usage/help =="
tbegin "usage mentions key options"
usage_out="$(usage)"
for opt in "--user" "--password-stdin" "--no-swap" "--dry-run" "--force-os"; do
    case "${usage_out}" in
        *"${opt}"*) ;;
        *) tfail "usage missing ${opt}"; break ;;
    esac
done
tpass

teardown

echo ""
echo "==================================="
echo " Unit tests: ${PASS} passed, ${FAIL} failed"
echo "==================================="
[ "${FAIL}" -eq 0 ]
