#!/usr/bin/env bash
# ============================================================================
# In-container post-install verification (run by tests/test-docker.sh)
# ----------------------------------------------------------------------------
# Checks the artifacts install.sh must have produced, then proves the xrdp
# services actually start and listen on TCP 3389 (no systemd inside these
# containers, so services are started directly — same as start.sh does).
# ============================================================================

set -o nounset
set -o pipefail

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
warn() { echo "  WARN  $1"; }

check() {  # check <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi
}

USER_NAME="${CLOUDDESK_USER:-cloudtest}"
USER_HOME="$(getent passwd "${USER_NAME}" | cut -d: -f6)"

echo "== commands =="
for b in xrdp xrdp-sesman startxfce4 xfwm4 xfsettingsd thunar xfce4-terminal nano; do
    check "command ${b}" command -v "${b}"
done
if command -v firefox >/dev/null 2>&1 || command -v firefox-esr >/dev/null 2>&1; then
    ok "firefox present"
else
    bad "firefox missing"
fi

echo "== user =="
check "user ${USER_NAME} exists" id "${USER_NAME}"

echo "== configuration files =="
check "startwm.sh executable" test -x /etc/xrdp/startwm.sh
if grep -q "dbus-run-session" /etc/xrdp/startwm.sh; then
    ok "startwm.sh starts XFCE via dbus-run-session"
else
    bad "startwm.sh wrong content"
fi
check "firefox policies installed" test -r /etc/firefox/policies/policies.json
check "wallpaper installed" test -r /usr/share/clouddesk/wallpaper.png
check "clouddesk CLI installed" test -x /usr/local/bin/clouddesk
check "xfce panel config deployed" test -r "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
check "xfce desktop config deployed" test -r "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"

if grep -q "/usr/share/clouddesk/wallpaper.png" \
        "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"; then
    ok "wallpaper wired into xfconf"
else
    bad "wallpaper not referenced in xfconf"
fi
if grep -q 'use_compositing" type="bool" value="false"' \
        "${USER_HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"; then
    ok "compositing disabled"
else
    bad "compositing not disabled"
fi
check "nano line numbers configured" grep -q "linenumbers" /etc/nanorc
check "nano tab-to-spaces configured" grep -q "tabstospaces" /etc/nanorc

echo "== dock and desktop =="
if command -v plank >/dev/null 2>&1; then
    check "plank dock settings present" test -r "${USER_HOME}/.config/plank/dock1/settings"
    if grep -q "firefox" "${USER_HOME}/.config/plank/dock1/settings"; then
        ok "dock contains firefox entry"
    else
        bad "dock missing firefox"
    fi
    if grep -q "xfce4-terminal" "${USER_HOME}/.config/plank/dock1/settings"; then
        ok "dock contains terminal entry"
    else
        bad "dock missing terminal"
    fi
    if grep -q "thunar" "${USER_HOME}/.config/plank/dock1/settings"; then
        ok "dock contains files entry"
    else
        bad "dock missing files"
    fi
else
    warn "plank not installed on this distro — dock skipped by design"
fi
for d in Firefox.desktop Files.desktop Settings.desktop Terminal.desktop; do
    check "desktop launcher ${d}" test -f "${USER_HOME}/Desktop/${d}"
done
check "Workspace folder created" test -d "${USER_HOME}/Workspace"

echo "== services actually start and listen (no systemd in container) =="
mkdir -p /var/run/xrdp
chown xrdp:xrdp /var/run/xrdp 2>/dev/null || true
rm -f /var/run/xrdp/*.pid
if xrdp-sesman >/dev/null 2>&1; then ok "xrdp-sesman started"; else bad "xrdp-sesman failed to start"; fi
sleep 1
if xrdp >/dev/null 2>&1; then ok "xrdp started"; else bad "xrdp failed to start"; fi
sleep 2
if ss -tln | grep -q ':3389 '; then ok "TCP 3389 listening"; else bad "TCP 3389 NOT listening"; fi

echo ""
echo "verify: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
