#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -euo pipefail

TARGET="${1:?Usage: admin-compact.sh <target> (siehe targets/*.env.example, README.md)}"

if [[ ! "${TARGET}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Zielserver-Name '${TARGET}' ungültig (nur Buchstaben, Ziffern, - und _)." >&2
    exit 1
fi

TARGET_ENV="${BASE_DIR}/targets/${TARGET}.env"

if [ ! -f "${TARGET_ENV}" ]; then
    echo "ERROR: ${TARGET_ENV} fehlt." >&2
    echo "Erst 'cp targets/example.env.example targets/${TARGET}.env' und ausfüllen (siehe README.md)." >&2
    exit 1
fi

export TARGET

cd "${BASE_DIR}"

set -a
# shellcheck source=/dev/null
source "${TARGET_ENV}"
set +a

LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/run/lock/docker-borg-backup-${TARGET}.lock"

# Retention für "borg prune". Optional per PRUNE_RETENTION in
# targets/<name>.env konfigurierbar (z.B. PRUNE_RETENTION="--keep-daily 14
# --keep-weekly 8 --keep-monthly 24"), sonst dieser Default:
PRUNE_RETENTION="${PRUNE_RETENTION:---keep-within 2d --keep-daily 7 --keep-weekly 3 --keep-monthly 12 --keep-yearly 2}"

# Uptime-Kuma-Push ist optional: nur aktiv, wenn beide Variablen gesetzt sind.
PUSH_URL=""
if [ -n "${UPTIME_KUMA_BASE_URL:-}" ] && [ -n "${UPTIME_KUMA_COMPACT_TOKEN:-}" ]; then
    PUSH_URL="${UPTIME_KUMA_BASE_URL}/api/push/${UPTIME_KUMA_COMPACT_TOKEN}"
fi

mkdir -p "${LOG_DIR}"

# Logs älter als 30 Tage löschen.
find "${LOG_DIR}" \
    -type f \
    -name "admin-compact-${TARGET}-*.log" \
    -mtime +30 \
    -delete \
    >/dev/null 2>&1 || true

# Pro Lauf eine eigene Logdatei, zusätzlich zur Ausgabe auf dem Terminal.
RUN_LOG="${LOG_DIR}/admin-compact-${TARGET}-$(date '+%Y-%m-%d_%H-%M-%S').log"

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "ERROR: SSH_AUTH_SOCK is not set."
    echo "Login using ssh -A first."
    exit 1
fi

echo "SSH agent:"
ssh-add -l

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    echo "Abbruch: Ein Backup- oder Maintenance-Lauf für Zielserver '${TARGET}' ist bereits aktiv."
    exit 1
fi

echo "Started: $(date -Is) (target: ${TARGET})" | tee "${RUN_LOG}"

START=$SECONDS

set +e
OUTPUT=$(
  (
    set -eo pipefail

    echo "=== Archives BEFORE maintenance ==="
    docker compose run --rm borg-admin list

    echo
    echo "=== Applying retention using ADMIN access ==="
    # shellcheck disable=SC2086  # PRUNE_RETENTION ist eine absichtliche Flag-Liste
    docker compose run --rm borg-admin prune \
        --list \
        --stats \
        --glob-archives="${ARCHIVE_PREFIX}-*" \
        ${PRUNE_RETENTION}

    echo
    echo "=== COMPACT ==="
    docker compose run --rm borg-admin compact

    echo
    echo "=== Archives AFTER maintenance ==="
    docker compose run --rm borg-admin list
  ) 2>&1
)
EXIT=$?
set -e

if [ -n "$OUTPUT" ]; then
    echo "$OUTPUT" | tee -a "${RUN_LOG}"
fi

DURATION=$(( SECONDS - START ))

{
    echo "Finished: $(date -Is)"
    echo "Return code: ${EXIT}"
} | tee -a "${RUN_LOG}"

if [ "${EXIT}" == "0" ]; then
    STATUS=up
    MSG="OK (${TARGET})"
else
    STATUS=down
    MSG="admin-compact fehlgeschlagen (${TARGET}, exit ${EXIT}): $(echo "$OUTPUT" | tail -n 5 | tr '\n' ' ')"
fi

if [ -n "${PUSH_URL}" ]; then
    curl -fsS --max-time 30 --get "${PUSH_URL}" \
        --data-urlencode "status=${STATUS}" \
        --data-urlencode "msg=${MSG}" \
        --data-urlencode "ping=$(( DURATION * 1000 ))" >/dev/null 2>&1 || true
fi

exit "${EXIT}"
