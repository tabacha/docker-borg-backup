#!/bin/bash
#
# Befüllt secrets/<target>/ (SSH-Keypaar, known_hosts, Passphrase) für die
# Ersteinrichtung EINES Zielservers. Idempotent: was schon da ist, wird
# nicht angefasst, beliebig oft erneut laufen lassen also unproblematisch.
#
# Läuft direkt auf dem Host, wenn dort ssh-keygen/ssh-keyscan vorhanden sind
# (./setup-secrets.sh <target>), oder ganz ohne Repo-Klon nur mit Docker -
# das Skript liegt im Image fest unter /usr/local/bin/setup-secrets.sh.
# BASE_DIR zeigt dann sonst auf /usr/local/bin, deshalb hier per -e
# überschreiben:
#
#   docker run --rm -v "$(pwd):/work" -e BASE_DIR=/work \
#       --entrypoint /usr/local/bin/setup-secrets.sh \
#       ghcr.io/tabacha/docker-borg-backup:latest <target>

set -euo pipefail

BASE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

TARGET="${1:?Usage: setup-secrets.sh <target> (siehe targets/*.env.example, README.md)}"

if [[ ! "${TARGET}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR: Zielserver-Name '${TARGET}' ungültig (nur Buchstaben, Ziffern, - und _)."
    exit 1
fi

TARGET_ENV="${BASE_DIR}/targets/${TARGET}.env"
SECRETS_DIR="${BASE_DIR}/secrets/${TARGET}"

if [ ! -f "${TARGET_ENV}" ]; then
    echo "ERROR: ${TARGET_ENV} fehlt."
    echo "Erst 'cp targets/example.env.example targets/${TARGET}.env' und ausfüllen (siehe README.md)."
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${TARGET_ENV}"
set +a

mkdir -p "${SECRETS_DIR}"

if [ -f "${SECRETS_DIR}/backup_ed25519" ]; then
    echo "secrets/${TARGET}/backup_ed25519 existiert schon, überspringe."
else
    echo "Erzeuge secrets/${TARGET}/backup_ed25519 ..."
    ssh-keygen -t ed25519 -f "${SECRETS_DIR}/backup_ed25519" -C "borg-backup-${TARGET}" -N ""
    chmod 600 "${SECRETS_DIR}/backup_ed25519"
    chmod 644 "${SECRETS_DIR}/backup_ed25519.pub"
fi

echo
echo "Public Key des Backup-Keys für Zielserver '${TARGET}' - beim Repo-Provider hinterlegen:"
cat "${SECRETS_DIR}/backup_ed25519.pub"
echo
echo "Der Backup-Key läuft unbeaufsichtigt (siehe README 'Sicherheit: zwei"
echo "Schlüssel gegen Ransomware') und sollte serverseitig auf Append-Only"
echo "beschränkt werden - er darf Archive schreiben, aber nichts löschen."
echo "Bei einem generischen SSH-Server dafür NICHT den Public Key direkt in"
echo "authorized_keys eintragen, sondern mit vorangestelltem Forced Command:"
echo
echo "  command=\"${BORG_REMOTE_PATH} serve --append-only --restrict-to-repository ${BORG_REPO_PATH}\",restrict $(cat "${SECRETS_DIR}/backup_ed25519.pub")"
echo
echo "Bei einer Hetzner Storage Box: Public Key ganz normal hinterlegen,"
echo "Append-Only läuft dort separat über ein eigenes Sub-Konto (siehe"
echo "README, dort auch der Link auf Hetzners Doku dazu)."

if [ -s "${SECRETS_DIR}/known_hosts" ]; then
    echo "secrets/${TARGET}/known_hosts existiert schon, überspringe."
else
    echo "Erzeuge secrets/${TARGET}/known_hosts (ssh-keyscan ${BORG_SSH_HOST}:${BORG_SSH_PORT}) ..."
    ssh-keyscan -p "${BORG_SSH_PORT}" "${BORG_SSH_HOST}" > "${SECRETS_DIR}/known_hosts"
fi

if [ -s "${SECRETS_DIR}/passphrase" ]; then
    echo "secrets/${TARGET}/passphrase existiert schon, überspringe."
else
    echo "Erzeuge secrets/${TARGET}/passphrase (zufällig, 48 Bytes) ..."
    python3 -c "import secrets; print(secrets.token_urlsafe(48))" > "${SECRETS_DIR}/passphrase"
    chmod 600 "${SECRETS_DIR}/passphrase"
fi

echo
echo "secrets/${TARGET}/ ist bereit:"
ls -la "${SECRETS_DIR}"
