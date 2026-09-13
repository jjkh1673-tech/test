#!/bin/bash
# ============================================================================
# CloudDesk-RDP container entrypoint
# ----------------------------------------------------------------------------
# Security: RDP_PASSWORD is REQUIRED. A default password was removed on
# purpose — images with known credentials get compromised quickly once
# exposed to the internet.
# ============================================================================
set -e

if [ -z "${RDP_PASSWORD:-}" ]; then
    echo "=============================================================" >&2
    echo " ERROR: the RDP_PASSWORD environment variable is not set."     >&2
    echo ""                                                                 >&2
    echo " CloudDesk-RDP ships with NO default password on purpose."        >&2
    echo " Set a strong password before starting the container:"            >&2
    echo ""                                                                 >&2
    echo "   Docker:   docker run -e RDP_PASSWORD='S3cret!Pass' ..."        >&2
    echo "   Railway:  Service -> Variables -> RDP_PASSWORD"                >&2
    echo "=============================================================" >&2
    exit 1
fi

echo "========================================"
echo " CloudDesk-RDP (container)"
echo " Lightweight XFCE + Firefox ESR + xRDP"
echo "========================================"
echo "RDP user: ubuntu"

echo "ubuntu:${RDP_PASSWORD}" | chpasswd
unset RDP_PASSWORD   # do not keep the secret in the environment

mkdir -p /run/dbus /run/user/1000 /var/run/xrdp /home/ubuntu/Workspace
chown ubuntu:ubuntu /run/user/1000 /home/ubuntu/Workspace
chown xrdp:xrdp /var/run/xrdp

if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
    dbus-daemon --system || true
fi

rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid

echo "Starting xrdp-sesman..."
xrdp-sesman &
sleep 1

echo "Starting xrdp on port 3389..."
exec xrdp --nodaemon
