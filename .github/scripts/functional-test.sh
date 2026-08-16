#!/bin/bash
#
# Funktionstest für ein gebautes borg-admin-Image: kompletter Zyklus gegen
# ein lokales (Dateisystem-)Repo, kein SSH nötig. Wird von .github/workflows/
# ci.yml (bei jedem PR) und release.yml (vor dem GHCR-Push) aufgerufen:
#
#   .github/scripts/functional-test.sh <image-ref>
#
# Kann auch lokal laufen, um ein selbstgebautes Image vorab zu prüfen.

set -euo pipefail

IMAGE="${1:?Usage: functional-test.sh <image-ref>}"
PASSPHRASE="functional-test-not-a-real-secret"

WORKDIR="$(mktemp -d)"
cleanup() {
    # Container laufen als root, Dateien in den Bind-Mounts (repo/extract/mnt)
    # gehören daher root - zum Aufräumen ebenfalls per Container löschen,
    # statt dass der Host-User an "Keine Berechtigung" scheitert.
    docker run --rm -v "${WORKDIR}:/cleanup" --entrypoint rm "${IMAGE}" \
        -rf /cleanup/repo /cleanup/extract /cleanup/mnt >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

mkdir -p "${WORKDIR}/repo" "${WORKDIR}/source" "${WORKDIR}/extract" "${WORKDIR}/mnt"
echo "hello from functional-test" > "${WORKDIR}/source/testfile.txt"
mkdir -p "${WORKDIR}/source/subdir"
echo "nested file" > "${WORKDIR}/source/subdir/nested.txt"

borg() {
    docker run --rm \
        -v "${WORKDIR}/repo:/repo" \
        -v "${WORKDIR}/source:/source:ro" \
        -e BORG_REPO=/repo \
        -e BORG_PASSPHRASE="${PASSPHRASE}" \
        "${IMAGE}" "$@"
}

echo "=== borg --version ==="
borg --version

echo "=== pyfuse3 importierbar ==="
docker run --rm --entrypoint python "${IMAGE}" \
    -c "import pyfuse3; print('pyfuse3 OK', pyfuse3.__version__)"

echo "=== borg init ==="
borg init --encryption=repokey-blake2

echo "=== borg create ==="
borg create --stats ::functional-test /source

echo "=== borg list ==="
borg list

echo "=== borg info ==="
borg info ::functional-test

echo "=== borg check ==="
borg check

echo "=== borg extract + Inhalt vergleichen ==="
docker run --rm \
    -v "${WORKDIR}/repo:/repo" \
    -v "${WORKDIR}/extract:/extract" \
    -w /extract \
    -e BORG_REPO=/repo \
    -e BORG_PASSPHRASE="${PASSPHRASE}" \
    --entrypoint borg "${IMAGE}" \
    extract ::functional-test
diff -r "${WORKDIR}/source" "${WORKDIR}/extract/source"
echo "Extrahierter Inhalt stimmt mit Quelle überein."

echo "=== borg mount (FUSE) + Inhalt prüfen + umount ==="
docker run --rm \
    --device /dev/fuse \
    --cap-add SYS_ADMIN \
    --security-opt apparmor:unconfined \
    -v "${WORKDIR}/repo:/repo" \
    -v "${WORKDIR}/mnt:/mnt" \
    -e BORG_REPO=/repo \
    -e BORG_PASSPHRASE="${PASSPHRASE}" \
    --entrypoint bash "${IMAGE}" -c '
        set -euo pipefail
        borg mount ::functional-test /mnt
        test -f /mnt/source/testfile.txt
        test -f /mnt/source/subdir/nested.txt
        grep -q "hello from functional-test" /mnt/source/testfile.txt
        borg umount /mnt
        echo "FUSE-Mount OK"
    '

echo "=== borg prune --dry-run ==="
borg prune --list --dry-run --keep-within 1d

echo "=== borg delete + compact ==="
borg delete ::functional-test
borg compact

echo
echo "Funktionstest erfolgreich: ${IMAGE}"
