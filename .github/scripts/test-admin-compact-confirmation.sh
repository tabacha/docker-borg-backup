#!/bin/bash
#
# Regressionstest für die Nachfrage vor "compact" in admin-compact.sh
# (borgbackup/borg#3579: erst compact macht bis dahin nur als gelöscht
# markierte Daten unwiderruflich weg - siehe README ->
# "Sicherheit: zwei Schlüssel gegen Ransomware"). Ersetzt "docker" durch
# einen Fake, der borg-admin-Aufrufe simuliert statt echten Docker/SSH/Borg
# zu brauchen - läuft daher ohne Docker, schnell im lint-Job von ci.yml.
#
#   .github/scripts/test-admin-compact-confirmation.sh

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0

WORKDIR="$(mktemp -d)"
cleanup() {
    [ -n "${AGENT_PID:-}" ] && kill "${AGENT_PID}" >/dev/null 2>&1 || true
    rm -f "/run/lock/docker-borg-backup-${TARGET}.lock" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

TARGET="admin-compact-confirmation-test"

# Fake "docker": tut so, als kämen borg-admin list/prune/compact durch,
# ohne echtes Docker/SSH/Borg zu brauchen.
mkdir -p "${WORKDIR}/fakebin"
cat > "${WORKDIR}/fakebin/docker" <<'FAKE'
#!/bin/bash
case "$*" in
    *"borg-admin list"*)   echo "fake-archive-1  2026-08-10" ;;
    *"borg-admin prune"*)  echo "Keeping archive: fake-archive-1" ;;
    *"borg-admin compact"*) echo "COMPACT_RAN_MARKER" ;;
    *) echo "[fake docker] unhandled: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "${WORKDIR}/fakebin/docker"

mkdir -p "${BASE_DIR}/targets"
cat > "${BASE_DIR}/targets/${TARGET}.env" <<ENV
BORG_SSH_USER=fakeuser
BORG_SSH_HOST=fakehost
BORG_SSH_PORT=22
BORG_REPO_PATH=./fake-repo
BORG_REMOTE_PATH=borg
ARCHIVE_PREFIX=${TARGET}
BACKUP_SOURCE_DIRS=/tmp
ENV
cleanup_target_env() { rm -f "${BASE_DIR}/targets/${TARGET}.env"; }
trap 'cleanup_target_env; cleanup' EXIT

ssh-keygen -t ed25519 -N "" -f "${WORKDIR}/id_ed25519" -q
eval "$(ssh-agent -s)" >/dev/null
ssh-add "${WORKDIR}/id_ed25519" >/dev/null 2>&1

export PATH="${WORKDIR}/fakebin:${PATH}"

run_admin_compact() {
    # $1: was auf stdin kommt (Antwort auf die Nachfrage, oder leer für EOF)
    ( cd "${BASE_DIR}" && printf '%s' "$1" | bash ./admin-compact.sh "${TARGET}" 2>&1 )
}

check() {
    local desc="$1" expect_exit="$2" expect_compact="$3" input="$4"
    set +e
    OUTPUT="$(run_admin_compact "${input}")"
    RC=$?
    set -e

    local ok=1
    if [ "${RC}" -ne "${expect_exit}" ]; then
        echo "FAIL (${desc}): Exit-Code ${RC}, erwartet ${expect_exit}" >&2
        ok=0
    fi
    if echo "${OUTPUT}" | grep -q "COMPACT_RAN_MARKER"; then
        COMPACT_RAN=1
    else
        COMPACT_RAN=0
    fi
    if [ "${COMPACT_RAN}" -ne "${expect_compact}" ]; then
        echo "FAIL (${desc}): compact lief=${COMPACT_RAN}, erwartet=${expect_compact}" >&2
        echo "--- Output ---" >&2
        echo "${OUTPUT}" >&2
        ok=0
    fi
    if [ "${ok}" -eq 1 ]; then
        echo "OK: ${desc}"
    else
        FAIL=1
    fi
}

check "Bestätigung mit 'ja' - compact läuft"              0 1 $'ja\n'
check "Ablehnung mit 'nein' - compact läuft NICHT"        1 0 $'nein\n'
check "Leere Eingabe (nur Enter) - compact läuft NICHT"   1 0 $'\n'
check "Kein stdin (EOF) - bricht sicher ab"                1 0 ''

exit "${FAIL}"
