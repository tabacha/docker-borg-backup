#!/bin/bash
#
# Einmalige Migrationshilfe von v1.0.x (eine globale .env, ein Zielserver,
# secrets/ direkt im Projektverzeichnis) auf v1.1.0+ (benannte Zielserver,
# siehe README.md "Mehrere Zielserver"). Macht aus der bestehenden .env +
# secrets/ eine targets/<name>.env + secrets/<name>/ - am Borg-Repo, der
# Passphrase und den vorhandenen Archiven ändert sich dabei NICHTS, es wird
# nur lokal umsortiert.
#
# Usage: ./migrate-to-v1.1.sh <target-name>
#
# Lässt die alte .env unangetastet liegen (nur kopiert, nicht verschoben) -
# nach Kontrolle der neuen targets/<name>.env selbst löschen. Secrets werden
# nach secrets/<name>/ verschoben (nicht kopiert), damit keine zweite Kopie
# des privaten Schlüssels rumliegt.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:?Usage: migrate-to-v1.1.sh <target-name>}"

if [[ ! "${TARGET}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Zielserver-Name '${TARGET}' ungültig (nur Buchstaben, Ziffern, - und _)."
    exit 1
fi

OLD_ENV="${BASE_DIR}/.env"
NEW_TARGET_ENV="${BASE_DIR}/targets/${TARGET}.env"
OLD_SECRETS="${BASE_DIR}/secrets"
NEW_SECRETS="${BASE_DIR}/secrets/${TARGET}"

if [ ! -f "${OLD_ENV}" ]; then
    echo "ERROR: ${OLD_ENV} nicht gefunden - nichts zu migrieren (schon migriert?)."
    exit 1
fi

if [ -f "${NEW_TARGET_ENV}" ]; then
    echo "ERROR: ${NEW_TARGET_ENV} existiert schon - breche ab, um nichts zu überschreiben."
    exit 1
fi

mkdir -p "${BASE_DIR}/targets" "${NEW_SECRETS}"

echo "Erzeuge ${NEW_TARGET_ENV} aus ${OLD_ENV} (BACKUP_SOURCE_DIR -> BACKUP_SOURCE_DIRS umbenannt) ..."
sed 's/^BACKUP_SOURCE_DIR=/BACKUP_SOURCE_DIRS=/' "${OLD_ENV}" > "${NEW_TARGET_ENV}"

MOVED=0
for f in backup_ed25519 backup_ed25519.pub known_hosts passphrase; do
    if [ -f "${OLD_SECRETS}/${f}" ]; then
        mv "${OLD_SECRETS}/${f}" "${NEW_SECRETS}/${f}"
        MOVED=$((MOVED + 1))
    fi
done

echo
echo "Fertig: ${MOVED} Secret-Dateien nach secrets/${TARGET}/ verschoben."
echo
echo "${OLD_ENV} wird nicht mehr benutzt (Inhalt liegt jetzt umbenannt in"
echo "${NEW_TARGET_ENV}) - nach Kontrolle selbst löschen: rm ${OLD_ENV}"
echo
echo "Noch zu erledigen:"
echo "  - Cron-/SSH-Aufrufe um den Zielserver-Namen ergänzen, z.B.:"
echo "      backup.sh ${TARGET}"
echo "      admin-compact.sh ${TARGET}"
echo "      admin-shell.sh ${TARGET}"
echo "  - Neues Notfall-Blatt erzeugen: ./disaster-recovery-info.sh ${TARGET}"
echo
echo "Details: README.md -> 'Migration von v1.0.x auf v1.1.0'"
