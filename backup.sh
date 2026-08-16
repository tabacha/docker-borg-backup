#!/bin/bash

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
source "${BASE_DIR}/.env"
set +a

LOG_DIR="${BASE_DIR}/logs"
LOCK_FILE="/run/lock/docker-borg-backup.lock"
SSH_KEY="${BASE_DIR}/secrets/backup_ed25519"

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
    -name 'backup-*.log' \
    -mtime +30 \
    -delete \
    >/dev/null 2>&1 || true

# Pro Lauf eine eigene Logdatei.
RUN_LOG="${LOG_DIR}/backup-$(date '+%Y-%m-%d_%H-%M-%S').log"

# Ab hier absolut keine Ausgabe mehr auf stdout/stderr.
exec >"${RUN_LOG}" 2>&1

# Exklusiver Lock.
exec 9>"${LOCK_FILE}"

# Wenn bereits ein Backup läuft: still beenden.
if ! flock -n 9; then
    exit 0
fi

cd "${BASE_DIR}"

echo "Started: $(date -Is)"

# Eigenen SSH-Agent starten und am Ende in jedem Fall wieder entladen.
eval "$(ssh-agent -s)"
trap 'ssh-agent -k >/dev/null' EXIT

ssh-add "${SSH_KEY}"
export SSH_AUTH_SOCK

START=$SECONDS

if docker compose \
       run --rm borg-admin \
       create \
        --lock-wait 600 \
	--stats \
	--show-rc \
	--compression zstd,6 \
	"::${HOST}-{now:%Y-%m-%dT%H:%M:%S}" \
	/source
then
    RC=0
else
    RC=$?
fi

DURATION=$(( SECONDS - START ))

echo "Finished: $(date -Is)"
echo "Return code: ${RC}"

if [ "${RC}" == "0" ]; then
    STATUS=up
    MSG="OK"
else
    STATUS=down
    MSG="borg backup fehlgeschlagen (exit ${RC}): $(tail -n 5 "${RUN_LOG}" | tr '\n' ' ')"
fi

if [ -n "${PUSH_URL}" ]; then
    curl -fsS --max-time 30 --get "${PUSH_URL}" \
        --data-urlencode "status=${STATUS}" \
        --data-urlencode "msg=${MSG}" \
        --data-urlencode "ping=$(( DURATION * 1000 ))" >/dev/null 2>&1 || true
fi

exit "${RC}"


