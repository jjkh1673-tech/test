#!/bin/sh
# CloudDesk-RDP session startup — executed by xrdp-sesman for every RDP login.
# Boots a private D-Bus session, then the XFCE desktop.
#
# Why dbus-run-session: under xrdp the login environment often carries stale
# DBUS_SESSION_BUS_ADDRESS / XDG_RUNTIME_DIR values from the display manager
# context. A clean per-session bus avoids "Could not connect to session bus"
# failures and orphaned xfconfd instances.

# Load system locale defaults when available.
if [ -r /etc/default/locale ]; then
    . /etc/default/locale
    export LANG LANGUAGE
fi

export XDG_CURRENT_DESKTOP=XFCE
export XDG_SESSION_DESKTOP=xfce
export DESKTOP_SESSION=xfce

# Drop environment inherited from sesman that can poison session D-Bus setup.
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Remove stale session leftovers (crashed sessions, rebooted hosts).
rm -rf "${HOME}/.cache/sessions" 2>/dev/null || true

if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- /usr/bin/startxfce4
fi

# Fallback (should not happen on a supported distro: dbus-x11 is required).
exec /usr/bin/startxfce4
