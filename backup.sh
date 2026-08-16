#!/bin/bash

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:?Usage: backup.sh <target> (siehe targets/*.env.example, README.md)}"

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

set -a
# shellcheck source=/dev/null
source "${TARGET_ENV}"
set +a

LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/run/lock/docker-borg-backup-${TARGET}.lock"
SSH_KEY="${BASE_DIR}/secrets/${TARGET}/backup_ed25519"

# Uptime-Kuma-Push ist optional: nur aktiv, wenn beide Variablen gesetzt sind.
PUSH_URL=""
if [ -n "${UPTIME_KUMA_BASE_URL:-}" ] && [ -n "${UPTIME_KUMA_BACKUP_TOKEN:-}" ]; then
    PUSH_URL="${UPTIME_KUMA_BASE_URL}/api/push/${UPTIME_KUMA_BACKUP_TOKEN}"
fi

HOST="${ARCHIVE_PREFIX}"

mkdir -p "${LOG_DIR}"

# Logs älter als 30 Tage löschen.
find "${LOG_DIR}" \
    -type f \
    -name "backup-${TARGET}-*.log" \
    -mtime +30 \
    -delete \
    >/dev/null 2>&1 || true

# Pro Lauf eine eigene Logdatei.
RUN_LOG="${LOG_DIR}/backup-${TARGET}-$(date '+%Y-%m-%d_%H-%M-%S').log"

# Ab hier absolut keine Ausgabe mehr auf stdout/stderr.
exec >"${RUN_LOG}" 2>&1

# Exklusiver Lock, pro Zielserver - Backups zu verschiedenen Zielservern
# blockieren sich dadurch nicht gegenseitig.
exec 9>"${LOCK_FILE}"

# Wenn für diesen Zielserver bereits ein Backup läuft: still beenden.
if ! flock -n 9; then
    exit 0
fi

cd "${BASE_DIR}"

echo "Started: $(date -Is) (target: ${TARGET})"

# Eigenen SSH-Agent starten und am Ende in jedem Fall wieder entladen.
eval "$(ssh-agent -s)"
trap 'ssh-agent -k >/dev/null' EXIT

ssh-add "${SSH_KEY}"
export SSH_AUTH_SOCK

# Quellpfade aus BACKUP_SOURCE_DIRS (leerzeichengetrennt) einzeln unter
# /source/<lfd. Nummer> mounten - erlaubt mehrere unabhängige
# Verzeichnisbäume ohne gemeinsames Elternverzeichnis.
read -ra SOURCE_DIRS <<< "${BACKUP_SOURCE_DIRS}"

VOLUME_ARGS=()
SOURCE_PATHS=()
i=0
for DIR in "${SOURCE_DIRS[@]}"; do
    i=$((i + 1))
    VOLUME_ARGS+=(-v "${DIR}:/source/${i}:ro")
    SOURCE_PATHS+=("/source/${i}")
done

START=$SECONDS

# Optionaler Pre-Backup-Hook (z.B. "mongodump" vor dem Sichern einer
# laufenden MongoDB-Instanz). Schlägt er fehl, wird "borg create"
# übersprungen und der Lauf gilt als fehlgeschlagen.
HOOK_OK=1
if [ -n "${PRE_BACKUP_HOOK:-}" ]; then
    echo "=== Pre-Backup-Hook ==="
    if ! bash -c "${PRE_BACKUP_HOOK}"; then
        HOOK_OK=0
    fi
fi

if [ "${HOOK_OK}" -eq 1 ]; then
    # shellcheck disable=SC2086  # BORG_CREATE_EXTRA_ARGS ist eine absichtliche Flag-Liste
    if docker compose \
           run --rm "${VOLUME_ARGS[@]}" borg-admin \
           create \
           --lock-wait 600 \
           --stats \
           --show-rc \
           --compression zstd,6 \
           ${BORG_CREATE_EXTRA_ARGS:-} \
           "::${HOST}-{now:%Y-%m-%dT%H:%M:%S}" \
           "${SOURCE_PATHS[@]}"
    then
        RC=0
    else
        RC=$?
    fi
else
    echo "Pre-Backup-Hook fehlgeschlagen - borg create wird übersprungen."
    RC=1
fi

DURATION=$(( SECONDS - START ))

echo "Finished: $(date -Is)"
echo "Return code: ${RC}"

if [ "${RC}" == "0" ]; then
    STATUS=up
    MSG="OK (${TARGET})"
else
    STATUS=down
    MSG="borg backup fehlgeschlagen (${TARGET}, exit ${RC}): $(tail -n 5 "${RUN_LOG}" | tr '\n' ' ')"
fi

if [ -n "${PUSH_URL}" ]; then
    curl -fsS --max-time 30 --get "${PUSH_URL}" \
        --data-urlencode "status=${STATUS}" \
        --data-urlencode "msg=${MSG}" \
        --data-urlencode "ping=$(( DURATION * 1000 ))" >/dev/null 2>&1 || true
fi

exit "${RC}"
