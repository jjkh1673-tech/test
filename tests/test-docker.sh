#!/usr/bin/env bash
# ============================================================================
# CloudDesk-RDP end-to-end test harness (Docker)
# ----------------------------------------------------------------------------
# Builds disposable images (Debian 12 / Ubuntu 24.04), runs the real
# installer inside them, verifies the result, tests installer idempotency,
# then runs the uninstaller and verifies the removal.
#
# REQUIREMENTS: docker. This harness cannot run in build sandboxes without
# docker; on any Linux machine with docker simply run:
#
#     ./tests/test-docker.sh debian12
#     ./tests/test-docker.sh ubuntu2404
#     ./tests/test-docker.sh all
# ============================================================================

set -o nounset
set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

IMAGE_PREFIX="clouddesk-test"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required for this end-to-end harness." >&2
    echo "The static and unit test suites (run-tests.sh, unit-tests.sh) work without it." >&2
    exit 1
fi

build_and_test() {
    local name="$1" dockerfile="$2"
    local image="${IMAGE_PREFIX}:${name}"

    echo ""
    echo "============================================================"
    echo " E2E: ${name}"
    echo "============================================================"

    echo "--- building image ${image} (installs the full desktop stack) ---"
    if ! docker build -f "${TESTS_DIR}/docker/${dockerfile}" -t "${image}" "${PROJECT_DIR}"; then
        echo "RESULT ${name}: FAIL (docker build / install.sh)"
        return 1
    fi

    echo "--- post-install verification ---"
    if ! docker run --rm "${image}" /opt/CloudDesk-RDP/tests/docker/verify.sh; then
        echo "RESULT ${name}: FAIL (verify.sh)"
        return 1
    fi

    echo "--- idempotency: installer re-run inside container ---"
    if ! docker run --rm "${image}" bash -c "/opt/CloudDesk-RDP/install.sh >/tmp/rerun.log 2>&1"; then
        echo "RESULT ${name}: FAIL (idempotent re-run)"
        docker run --rm "${image}" tail -20 /tmp/rerun.log || true
        return 1
    fi

    echo "--- uninstall verification ---"
    if ! docker run --rm "${image}" bash -c \
        "/opt/CloudDesk-RDP/uninstall.sh --yes >/tmp/uninstall.log 2>&1 && /opt/CloudDesk-RDP/tests/docker/verify-uninstall.sh"; then
        echo "RESULT ${name}: FAIL (uninstall)"
        docker run --rm "${image}" tail -20 /tmp/uninstall.log || true
        return 1
    fi

    echo "RESULT ${name}: PASS"
    return 0
}

TARGET="${1:-all}"
overall=0

case "${TARGET}" in
    debian12)    build_and_test "debian12"    "Dockerfile.debian12"    || overall=1 ;;
    ubuntu2404)  build_and_test "ubuntu2404"  "Dockerfile.ubuntu2404"  || overall=1 ;;
    all)
        build_and_test "debian12"   "Dockerfile.debian12"   || overall=1
        build_and_test "ubuntu2404" "Dockerfile.ubuntu2404" || overall=1
        ;;
    *)
        echo "Usage: $0 [debian12|ubuntu2404|all]" >&2
        exit 1
        ;;
esac

if [ "${overall}" -eq 0 ]; then
    echo ""
    echo "E2E SUMMARY: ALL PASS"
else
    echo ""
    echo "E2E SUMMARY: FAILURES DETECTED"
fi
exit "${overall}"
