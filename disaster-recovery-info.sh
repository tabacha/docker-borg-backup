#!/bin/bash
#
# Stellt alles zusammen, was man für einen Full-Restore braucht, WENN dieser
# Host komplett weg ist und nur noch ein privater SSH-Key übrig ist (z.B. aus
# einem Passwort-Tresor). Ohne diesen Key nutzt die Ausgabe hier nichts -
# und ohne diese Ausgabe nutzt der Key allein auch nichts (Repo-Adresse und
# Passphrase kennt sonst niemand mehr).
#
# Macht NICHTS am Repo, spricht nicht mal mit Docker - liest nur lokale
# Dateien und druckt. Schreibt absichtlich NICHT nach logs/, weil die
# Ausgabe die Repo-Passphrase im Klartext enthält.
#
# Ein Blatt gilt für GENAU EINEN Zielserver: ./disaster-recovery-info.sh <target>

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${1:?Usage: disaster-recovery-info.sh <target> (siehe targets/*.env.example)}"

if [[ ! "${TARGET}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Zielserver-Name '${TARGET}' ungültig (nur Buchstaben, Ziffern, - und _)." >&2
    exit 1
fi

TARGET_ENV="${BASE_DIR}/targets/${TARGET}.env"

if [ ! -f "${TARGET_ENV}" ]; then
    echo "ERROR: ${TARGET_ENV} fehlt." >&2
    exit 1
fi

set -a
source "${BASE_DIR}/.env"
# shellcheck source=/dev/null
source "${TARGET_ENV}"
set +a

PASSPHRASE="$(cat "${BASE_DIR}/secrets/${TARGET}/passphrase")"
KNOWN_HOSTS="$(cat "${BASE_DIR}/secrets/${TARGET}/known_hosts")"

BORG_REPO="ssh://${BORG_SSH_USER}@${BORG_SSH_HOST}:${BORG_SSH_PORT}/${BORG_REPO_PATH}"

cat <<EOF
============================================================================
 DISASTER-RECOVERY-INFO - Zielserver "${TARGET}" - erzeugt $(date -Is)
============================================================================

GEHEIM! Diese Ausgabe enthält die Repo-Passphrase im Klartext - genauso
schützen wie den privaten SSH-Key selbst. Nicht auf diesem Host liegen
lassen: ausdrucken + in einen Safe, oder als Secure Note in den
Passwort-Tresor - getrennt vom Host, aber NAH beim Key, denn beides
zusammen ergibt erst einen Restore. Gilt nur für den Zielserver "${TARGET}"
- bei mehreren Zielservern für jeden ein eigenes Blatt erzeugen.

  1. Ein privater SSH-Key, der beim Repo-Provider hinterlegt ist
     (${BASE_DIR}/secrets/${TARGET}/backup_ed25519 oder ein Admin-Key)
  2. Dieses Blatt (Repo-Adresse + Passphrase + Host-Key)
  3. Irgendeine Linux-Maschine mit Python/pip ODER Docker

----------------------------------------------------------------------------
 Repo-Zugangsdaten
----------------------------------------------------------------------------

BORG_REPO="${BORG_REPO}"
BORG_REMOTE_PATH="${BORG_REMOTE_PATH}"
BORG_PASSPHRASE="${PASSPHRASE}"

SSH-Hostkey (secrets/${TARGET}/known_hosts, für Pinning - verhindert MITM
beim allerersten Connect):
${KNOWN_HOSTS}

Archiv-Präfix zur Orientierung (::${ARCHIVE_PREFIX}-<zeitstempel>):
${ARCHIVE_PREFIX}-*

----------------------------------------------------------------------------
 Restore auf einer nackten Linux-Maschine (kein Docker, kein Git-Checkout
 dieses Repos nötig - nur der Key + diese Werte)
----------------------------------------------------------------------------

# borg installieren, falls nicht vorhanden:
pip install --user "borgbackup==1.4.5"

# Mitgebrachten Key + Hostkey vorbereiten:
cp /pfad/zum/mitgebrachten/key ./restore_key
chmod 600 ./restore_key
cat > ./known_hosts <<'HOSTKEYS'
${KNOWN_HOSTS}
HOSTKEYS

export BORG_REPO="${BORG_REPO}"
export BORG_REMOTE_PATH="${BORG_REMOTE_PATH}"
export BORG_PASSPHRASE="${PASSPHRASE}"
export BORG_RSH="ssh -p ${BORG_SSH_PORT} -i ./restore_key -o IdentitiesOnly=yes -o UserKnownHostsFile=./known_hosts -o StrictHostKeyChecking=yes"

borg list                        # Welche Archive gibt es?
borg extract ::<archiv>          # Alles wiederherstellen (ins aktuelle Verzeichnis)
# gezielt:
borg extract ::<archiv> pfad/im/backup

----------------------------------------------------------------------------
 Restore mit diesem Repo (falls Git-Checkout + Docker verfügbar sind)
----------------------------------------------------------------------------

git clone git@github.com:tabacha/docker-borg-backup.git && cd docker-borg-backup
cp .env.example .env    # BACKUP_SOURCE_DIRS nach Bedarf füllen
mkdir -p secrets/${TARGET}
cp targets/example.env.example targets/${TARGET}.env
# targets/${TARGET}.env mit den obigen Werten füllen (BORG_SSH_USER=...,
# BORG_SSH_HOST=..., BORG_SSH_PORT=${BORG_SSH_PORT}, BORG_REPO_PATH=...,
# BORG_REMOTE_PATH=..., ARCHIVE_PREFIX=${ARCHIVE_PREFIX})
cp /pfad/zum/mitgebrachten/key secrets/${TARGET}/backup_ed25519
chmod 600 secrets/${TARGET}/backup_ed25519
echo "${PASSPHRASE}" > secrets/${TARGET}/passphrase
chmod 600 secrets/${TARGET}/passphrase
cat > secrets/${TARGET}/known_hosts <<'HOSTKEYS'
${KNOWN_HOSTS}
HOSTKEYS

docker volume create docker-borg-backup_borg-cache
docker volume create docker-borg-backup_borg-config
docker compose build

# Dann normal per admin-shell.sh reingehen (SSH_AUTH_SOCK/TTY siehe README):
#   ssh -tA user@host /pfad/zum/geklonten/repo/admin-shell.sh ${TARGET}
# und darin: cd /restore && borg extract ::<archiv>
============================================================================
EOF
