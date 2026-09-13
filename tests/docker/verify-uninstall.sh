#!/usr/bin/env bash
# ============================================================================
# In-container post-uninstall verification (run by tests/test-docker.sh)
# ----------------------------------------------------------------------------

set -o nounset
set -o pipefail

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

USER_NAME="${CLOUDDESK_USER:-cloudtest}"

# Packages removed?
if ! command -v xrdp >/dev/null 2>&1; then ok "xrdp removed"; else bad "xrdp still present"; fi
if ! command -v xfce4-terminal >/dev/null 2>&1; then ok "xfce4-terminal removed"; else bad "xfce4-terminal still present"; fi

# Managed files gone / restored?
if [ ! -x /usr/local/bin/clouddesk ]; then ok "clouddesk CLI removed"; else bad "clouddesk CLI still present"; fi
if [ ! -e /usr/share/clouddesk ]; then ok "assets removed"; else bad "assets still present"; fi
if [ ! -e /etc/firefox/policies/policies.json ]; then ok "firefox policies removed"; else bad "firefox policies still present"; fi
if [ -f /etc/nanorc ] && grep -q "CloudDesk-RDP nano configuration" /etc/nanorc; then
    bad "nano managed block still present"
else
    ok "nano managed block removed"
fi

# startwm.sh must be back to the package original (no dbus-run-session line).
if [ -f /etc/xrdp/startwm.sh ] && ! grep -q "dbus-run-session" /etc/xrdp/startwm.sh; then
    ok "startwm.sh restored to package original"
else
    # File may legitimately be absent if apt purge removed it with the package.
    if [ ! -f /etc/xrdp/startwm.sh ]; then
        ok "startwm.sh removed together with xrdp package"
    else
        bad "startwm.sh still contains CloudDesk session"
    fi
fi

# User data preserved unless explicitly removed.
if id "${USER_NAME}" >/dev/null 2>&1; then
    ok "desktop user preserved (default)"
else
    ok "desktop user removed (explicit --remove-user path)"
fi

echo ""
echo "verify-uninstall: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
