#!/bin/bash
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${BASE_DIR}/logs"

set -euo pipefail

TARGET="${1:?Usage: admin-shell.sh <target> (siehe targets/*.env.example, README.md)}"

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

# docker compose lädt Compose-Variablen nicht automatisch aus
# targets/<name>.env (nur aus einer Datei namens ".env", die es hier nicht
# gibt) - deshalb hier explizit in die Shell-Umgebung exportieren, damit
# compose.yml BORG_SSH_USER & Co. für DIESEN Zielserver findet.
set -a
# shellcheck source=/dev/null
source "${TARGET_ENV}"
set +a

LOCK_FILE="/run/lock/docker-borg-backup-${TARGET}.lock"

mkdir -p "${LOG_DIR}"

# Logs älter als 30 Tage löschen.
find "${LOG_DIR}" \
    -type f \
    -name "admin-shell-${TARGET}-*.log" \
    -mtime +30 \
    -delete \
    >/dev/null 2>&1 || true

# Mitschnitt der kompletten Sitzung (Befehle + Ausgaben).
RUN_LOG="${LOG_DIR}/admin-shell-${TARGET}-$(date '+%Y-%m-%d_%H-%M-%S').log"

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "ERROR: SSH_AUTH_SOCK is not set."
    echo "Login using ssh -A first."
    exit 1
fi

if [ ! -t 0 ]; then
    echo "ERROR: Kein TTY auf stdin."
    echo "Bitte mit 'ssh -tA ...' bzw. 'ssh -tA root@host ${0} ${TARGET}' einloggen,"
    echo "sonst kann der Container kein interaktives Terminal bekommen."
    exit 1
fi

echo "SSH agent:"
ssh-add -l

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    echo "Abbruch: Ein Backup- oder Maintenance-Lauf für Zielserver '${TARGET}' ist bereits aktiv."
    exit 1
fi

cat <<EOF
============================================================================
 Interaktive Borg-Shell - Zielserver: ${TARGET}
============================================================================

BORG_REPO / BORG_PASSCOMMAND / BORG_RSH sind schon als Umgebungsvariablen
gesetzt, "borg" also ohne Repo-Pfad aufrufen. Ein paar Kommandos, die man
selten braucht, aber dann suchen muss:

  borg list                             Archive auflisten
  borg info ::<archiv>                  Details zu einem Archiv
  borg diff ::<alt> ::<neu>             Unterschiede zwischen 2 Archiven
  borg extract ::<archiv> [pfad...]     Wiederherstellen (siehe unten:
                                         vorher nach /restore wechseln!)
  borg delete ::<archiv>                EIN Archiv löschen (Vorsicht!)
  borg prune --list --dry-run ...       Retention testen, ohne zu löschen
  borg compact                          Freien Platz nach delete/prune
                                         zurückgeben

Nach alten Dateien suchen, ohne extrahieren zu müssen: Archiv per FUSE
einhängen und drin suchen, danach unbedingt wieder aushängen:

  mkdir -p /mnt/borg
  borg mount ::<archiv> /mnt/borg
  find /mnt/borg -iname '*muster*'
  # bzw. grep -r ... /mnt/borg
  borg umount /mnt/borg

ACHTUNG: borg mount lädt vor dem Mount die komplette Item-/Metadaten-
Liste des Archivs ins RAM (ohne Fortschrittsanzeige!). Das kann beim
ersten Aufruf gut und gerne 5 Minuten dauern und wirkt dabei wie ein
Hänger - einfach warten. Danach nur den gewünschten Pfad statt dem
ganzen Archiv mounten, das geht schneller:

  borg mount ::<archiv> /mnt/borg <pfad-im-backup>

/restore im Container ist auf ./restore im Projektverzeichnis auf dem
Host gemountet. Also VOR dem extract erst dahin wechseln, sonst landen
die Dateien nur im (ephemeren) Container und sind nach dem Beenden weg:

  cd /restore
  borg extract ::<archiv> [pfad...]

Die wiederhergestellten Dateien liegen danach unter
${BASE_DIR}/restore/ auf dem Host.

Solange diese Shell offen ist, halten wir den Lock: automatisches Backup
und admin-compact.sh für Zielserver '${TARGET}' warten, bis du fertig bist.

Diese Sitzung wird komplett (Befehle + Ausgaben) mitgeschnitten nach:
  ${RUN_LOG}

Shell mit "exit" verlassen, der Container wird danach automatisch entfernt.
============================================================================

EOF

CMD=(
    docker compose run --rm -it
    --entrypoint /bin/bash
    -e "PS1=\[\e[1;33m\][borg-admin:${TARGET}]\[\e[0m\] \w # "
    borg-admin
)

printf -v QUOTED_CMD '%q ' "${CMD[@]}"

# script(1) hängt sich als Pseudo-Terminal dazwischen und schreibt alles
# mit, was auf dem Terminal erscheint (inkl. Steuerzeichen/Farben).
script -q -c "${QUOTED_CMD}" "${RUN_LOG}"
