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
# --keep-weekly 8 --keep-monthly 24"), sonst dieser Default. Wie
# BORG_CREATE_EXTRA_ARGS in backup.sh: per read -ra in ein Array splitten,
# nicht unquoted expandieren - sonst wuerden eventuelle Glob-Sonderzeichen
# in der Variable von dieser Shell statt von borg interpretiert.
read -ra PRUNE_RETENTION_ARGS <<< "${PRUNE_RETENTION:---keep-within 2d --keep-daily 7 --keep-weekly 3 --keep-monthly 12 --keep-yearly 2}"

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
LIST_AND_PRUNE_OUTPUT=$(
  (
    set -eo pipefail

    echo "=== Archives BEFORE maintenance ==="
    docker compose run --rm borg-admin list

    echo
    echo "=== Applying retention using ADMIN access ==="
    docker compose run --rm borg-admin prune \
        --list \
        --stats \
        --glob-archives="${ARCHIVE_PREFIX}-*" \
        "${PRUNE_RETENTION_ARGS[@]}"
  ) 2>&1
)
EXIT=$?
set -e

if [ -n "${LIST_AND_PRUNE_OUTPUT}" ]; then
    echo "${LIST_AND_PRUNE_OUTPUT}" | tee -a "${RUN_LOG}"
fi

# compact ist der Punkt ohne Wiederkehr: solange nur "prune" lief, sind die
# betroffenen Daten dank Borgs Append-Only-Modell nur als gelöscht markiert,
# nicht physisch weg (siehe README -> "Sicherheit: zwei Schlüssel gegen
# Ransomware") - das gilt auch für alles, was VOR diesem Lauf schon markiert
# wurde, z.B. durch einen kompromittierten Backup-Key. Erst compact gibt den
# Platz wirklich frei und macht das unwiderruflich (borgbackup/borg#3579).
# Deshalb hier - mit dem prune-Output oben sichtbar vor Augen - noch einmal
# explizit nachfragen, bevor das passiert.
ABORTED_BY_USER=0
if [ "${EXIT}" -eq 0 ]; then
    echo
    if ! read -r -p "compact macht ALLE bisher für Zielserver '${TARGET}' als gelöscht markierten Daten unwiderruflich weg (auch was VOR diesem Lauf markiert wurde). Wirklich fortfahren? Zum Bestätigen 'ja' eingeben: " CONFIRM; then
        CONFIRM=""
    fi
    if [ "${CONFIRM,,}" != "ja" ]; then
        echo "Abgebrochen: compact wurde NICHT ausgeführt (Bestätigung fehlt/verweigert)." | tee -a "${RUN_LOG}"
        ABORTED_BY_USER=1
        EXIT=1
    else
        set +e
        COMPACT_OUTPUT=$(
          (
            set -eo pipefail

            echo "=== COMPACT ==="
            docker compose run --rm borg-admin compact

            echo
            echo "=== Archives AFTER maintenance ==="
            docker compose run --rm borg-admin list
          ) 2>&1
        )
        EXIT=$?
        set -e

        if [ -n "${COMPACT_OUTPUT}" ]; then
            echo "${COMPACT_OUTPUT}" | tee -a "${RUN_LOG}"
        fi
    fi
fi

DURATION=$(( SECONDS - START ))

{
    echo "Finished: $(date -Is)"
    echo "Return code: ${EXIT}"
} | tee -a "${RUN_LOG}"

if [ "${EXIT}" == "0" ]; then
    STATUS=up
    MSG="OK (${TARGET})"
elif [ "${ABORTED_BY_USER}" -eq 1 ]; then
    STATUS=down
    MSG="admin-compact abgebrochen (${TARGET}): compact durch Nutzer nicht bestätigt"
else
    STATUS=down
    MSG="admin-compact fehlgeschlagen (${TARGET}, exit ${EXIT}): $(tail -n 5 "${RUN_LOG}" | tr '\n' ' ')"
fi

if [ -n "${PUSH_URL}" ]; then
    curl -fsS --max-time 30 --get "${PUSH_URL}" \
        --data-urlencode "status=${STATUS}" \
        --data-urlencode "msg=${MSG}" \
        --data-urlencode "ping=$(( DURATION * 1000 ))" >/dev/null 2>&1 || true
fi

exit "${EXIT}"
