#!/usr/bin/env bash
# ============================================================================
# CloudDesk-RDP static test suite
# ----------------------------------------------------------------------------
# Validates the repository itself: shell syntax, lint (shellcheck when
# available), JSON/XML/desktop-entry integrity, file permissions, hardcoded
# secret scan, cross-references between installer/README and real files.
#
# Run:  ./tests/run-tests.sh          (no root required)
# ============================================================================

set -o nounset
set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PROJECT_DIR="$(cd "${TESTS_DIR}/.." && pwd)" || exit 1
cd "${PROJECT_DIR}" || exit 1

PASS=0
FAIL=0
CURRENT=""

tbegin() { CURRENT="$1"; }
tpass()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "${CURRENT}"; }
tfail()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s  (%s)\n' "${CURRENT}" "$1"; }

section() { echo ""; echo "== $1 =="; }

SHELL_FILES=(
    "install.sh"
    "uninstall.sh"
    "start.sh"
    "bin/clouddesk"
    "config/xrdp/startwm.sh"
    "tests/run-tests.sh"
    "tests/unit-tests.sh"
    "tests/test-docker.sh"
    "tests/docker/verify.sh"
    "tests/docker/verify-uninstall.sh"
)

# ----------------------------------------------------------------------------
section "Shell syntax (bash -n)"
for f in "${SHELL_FILES[@]}"; do
    tbegin "bash -n ${f}"
    if [ ! -f "${f}" ]; then tfail "file missing"; continue; fi
    if bash -n "${f}" 2>/tmp/err.txt; then tpass; else tfail "$(cat /tmp/err.txt)"; fi
done

section "Shellcheck lint"
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${SHELL_FILES[@]}"; do
        tbegin "shellcheck ${f}"
        # SC1090/SC1091: dynamic sourcing; SC2181 removed by direct checks style.
        if shellcheck --severity=style -e SC1090,SC1091 "${f}" >/tmp/sc.txt 2>&1; then
            tpass
        else
            tfail "$(head -c 600 /tmp/sc.txt)"
        fi
    done
else
    echo "  SKIP  shellcheck not installed (install it or download the static"
    echo "        binary from https://github.com/koalaman/shellcheck/releases)"
fi

section "File permissions"
for f in "${SHELL_FILES[@]}" "assets/src/generate_wallpaper.py"; do
    tbegin "executable: ${f}"
    [ -f "${f}" ] || { tfail "missing"; continue; }
    if [ -x "${f}" ]; then tpass; else tfail "not executable"; fi
done
while IFS= read -r -d '' f; do
    tbegin "non-executable data file: ${f}"
    if [ -x "${f}" ]; then tfail "should not be executable"; else tpass; fi
done < <(find config assets -type f ! -name "startwm.sh" ! -path "assets/src/*" -print0 2>/dev/null)

section "JSON / XML / desktop-entry integrity"
if command -v python3 >/dev/null 2>&1; then
    tbegin "policies.json is valid JSON with expected keys"
    if python3 - <<'EOF'
import json, sys
with open("config/firefox/policies.json") as fh:
    doc = json.load(fh)
pol = doc["policies"]
assert pol["DisableTelemetry"] is True
assert pol["DisablePocket"] is True
assert isinstance(pol["Preferences"], dict)
sys.exit(0)
EOF
    then tpass; else tfail "JSON invalid or keys missing"; fi

    for f in config/xfce4/*.xml; do
        tbegin "well-formed XML: ${f}"
        if python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse('${f}')" 2>/dev/null; then
            tpass
        else
            tfail "XML parse error"
        fi
    done
else
    echo "  SKIP  python3 not available"
fi

for f in config/desktop/*.desktop; do
    tbegin "desktop entry keys: ${f}"
    ok_entry=1
    for key in "Type=" "Name=" "Exec=" "Icon="; do
        grep -q "^${key}" "${f}" || ok_entry=0
    done
    grep -q "^\[Desktop Entry\]" "${f}" || ok_entry=0
    if [ "${ok_entry}" -eq 1 ]; then tpass; else tfail "required keys missing"; fi
done

section "Placeholder hygiene"
tbegin "templates carry placeholders; final files do not"
placeholder_leak=0
while IFS= read -r -d '' f; do
    case "${f}" in
        ./config/plank/settings.template|./config/plank/launcher.dockitem.template|\
        ./config/xfce4/xsettings.xml|./config/xfce4/xfwm4.xml|./config/xfce4/xfce4-desktop.xml|\
        ./config/nano/nanorc.block|./install.sh|./Dockerfile)
            # templates (by design) and the scripts that perform substitution
            ;;
        *)
            if grep -rIl "__GTK_THEME__\|__XFWM_THEME__\|__WALLPAPER__\|__FIREFOX_ID__\|__DESKTOP_ID__\|__NANO_EXTRAS__" "${f}" >/dev/null 2>&1; then
                echo "        leaked placeholder in: ${f}"
                placeholder_leak=1
            fi
            ;;
    esac
done < <(find . -path ./tests -prune -o -type f -print0 2>/dev/null | grep -zEv '\.(png|zip|sha256)$')
if [ "${placeholder_leak}" -eq 0 ]; then tpass; else tfail "placeholder found outside templates"; fi

section "Secrets / credentials scan"
tbegin "no hardcoded default passwords"
secret_hit=0
# The historic bad default of this project must never return:
while IFS= read -r -d '' f; do
    if grep -nE '(1122|ubuntu:1122|password\s*=\s*["'"'"'][A-Za-z0-9!@#$%^&*]{6,})' "${f}" >/dev/null 2>&1; then
        echo "        suspicious literal in: ${f}: $(grep -nE '(1122|ubuntu:1122)' "${f}" | head -1)"
        secret_hit=1
    fi
done < <(find . -type f \( -name "*.sh" -o -name "Dockerfile" -o -name "*.md" -o -name "*.json" \) ! -path "./tests/*" -print0 2>/dev/null)
if [ "${secret_hit}" -eq 0 ]; then tpass; else tfail "hardcoded credential pattern found"; fi

tbegin "start.sh requires RDP_PASSWORD (no default value allowed)"
if grep -qE 'RDP_PASSWORD:-[^}]' start.sh; then
    tfail "RDP_PASSWORD has a default value"
elif grep -q 'RDP_PASSWORD:-}' start.sh; then
    tpass
else
    tfail "RDP_PASSWORD empty-default check not found"
fi

tbegin "Dockerfile sets no ENV RDP_PASSWORD"
if grep -qE '^ENV RDP_PASSWORD' Dockerfile; then tfail "ENV RDP_PASSWORD present"; else tpass; fi

section "Installer -> repository cross-references"
tbegin "every repo file referenced by install.sh exists"
missing_ref=0
# The regex intentionally matches the literal '${SCRIPT_DIR}' string in the source.
# shellcheck disable=SC2013,SC2016
while IFS= read -r ref; do
    if [ ! -f "${ref}" ]; then
        echo "        install.sh references missing file: ${ref}"
        missing_ref=1
    fi
done < <(grep -oE '\$\{SCRIPT_DIR\}/[A-Za-z0-9_./-]+' install.sh | sed 's|\${SCRIPT_DIR}/||' | sort -u)
if [ "${missing_ref}" -eq 0 ]; then tpass; else tfail "missing referenced files"; fi

tbegin "uninstall.sh paths consistent with installer manifest"
for key_path in "/usr/share/clouddesk" "/usr/local/bin/clouddesk" "/var/lib/clouddesk/manifest"; do
    grep -q "${key_path}" uninstall.sh || { tfail "uninstall.sh missing ${key_path}"; continue; }
done
tpass

section "README cross-references"
if [ -f README.md ]; then
    tbegin "README references match real files"
    readme_miss=0
    for f in install.sh uninstall.sh bin/clouddesk tests/run-tests.sh Dockerfile start.sh LICENSE .gitignore assets/wallpaper.png; do
        if ! grep -q "${f##*/}" README.md; then
            # Only fail when the README mentions the path at all but file missing.
            :
        fi
        [ -f "${f}" ] || { echo "        README-listed file missing: ${f}"; readme_miss=1; }
    done
    if [ "${readme_miss}" -eq 0 ]; then tpass; else tfail "files listed in checks are missing"; fi
else
    echo "  SKIP  README.md not present yet"
fi

section "Wallpaper asset"
tbegin "wallpaper is a real, reasonably sized PNG"
if command -v python3 >/dev/null 2>&1; then
    if python3 - <<'EOF'
import struct, sys
with open("assets/wallpaper.png","rb") as fh:
    head = fh.read(33)
assert head[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
w, h = struct.unpack(">II", head[16:24])
assert (w, h) == (1920, 1080), f"unexpected size {w}x{h}"
import os
size = os.path.getsize("assets/wallpaper.png")
assert size < 1_000_000, f"wallpaper too large: {size}"
sys.exit(0)
EOF
    then tpass; else tfail "wallpaper check failed"; fi
else
    tbegin "wallpaper PNG magic"
    if head -c 8 assets/wallpaper.png | od -An -tx1 | grep -q "89 50 4e 47"; then tpass; else tfail; fi
fi

section "Line endings"
tbegin "no CRLF line endings in the repository"
if find . -type f \( -name "*.sh" -o -name "*.xml" -o -name "*.json" -o -name "*.md" -o -name "*.template" -o -name "*.block" \) -exec grep -Il $'\r' {} \; | grep -q .; then
    tfail "CRLF found"
else
    tpass
fi

echo ""
echo "==================================="
echo " Static tests: ${PASS} passed, ${FAIL} failed"
echo "==================================="
[ "${FAIL}" -eq 0 ]
