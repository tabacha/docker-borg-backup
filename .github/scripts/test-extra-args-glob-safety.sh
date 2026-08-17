#!/bin/bash
#
# Regressionstest: BORG_CREATE_EXTRA_ARGS (backup.sh) und PRUNE_RETENTION
# (admin-compact.sh) dürfen NIE unquoted expandiert werden. Unquoted würde
# die Backup-Host-Shell nicht nur auf Leerzeichen splitten, sondern
# zusätzlich Pathname-Expansion (Globbing) anwenden - Exclude-Muster wie
# "*/ImapMail" würden dann relativ zu BASE_DIR (statt von borg) ausgewertet
# und je nach zufälligem Treffer im Repo-Arbeitsverzeichnis verstümmelt.
# Kein Docker nötig, läuft daher im lint-Job von ci.yml.
#
#   .github/scripts/test-extra-args-glob-safety.sh

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAIL=0

# --- 1. Statischer Guard: kein unquoted "${VAR}"/"${VAR:-...}" mehr direkt
# im docker-compose-Aufruf. Verhindert, dass jemand versehentlich zur alten,
# von shellcheck (SC2086) explizit als unsicher markierten Variante
# zurückwechselt.
for pair in "backup.sh:BORG_CREATE_EXTRA_ARGS" "admin-compact.sh:PRUNE_RETENTION"; do
    FILE="${pair%%:*}"
    VAR="${pair#*:}"
    # "${VAR:-...}" ist nur in Ordnung als Quelle von "read -ra ... <<< ...";
    # dort expandiert die Shell die Variable ganz normal (quoted, kein
    # Globbing möglich), read splittet den resultierenden String danach
    # selbst. Jedes andere Vorkommen ist die alte, unsichere Direktnutzung.
    if grep -E '\$\{'"${VAR}"'(:-[^}]*)?\}' "${BASE_DIR}/${FILE}" \
        | grep -v 'read -ra' | grep -q .; then
        echo "FAIL: ${FILE} scheint ${VAR} wieder unquoted zu expandieren." >&2
        FAIL=1
    fi
done

# --- 2. Dynamischer Nachweis: read -ra <<< "$VAR" globbt nicht, selbst wenn
# das Arbeitsverzeichnis zufällig einen Pfad enthält, der zum Muster passt -
# im Gegensatz zur alten unquoted Variante.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
mkdir -p "${WORKDIR}/x/ImapMail"
cd "${WORKDIR}"

EXTRA_ARGS_VALUE="--exclude */ImapMail --exclude */.cache"

read -ra FIXED_ARR <<< "${EXTRA_ARGS_VALUE}"
if [ "${FIXED_ARR[1]}" != "*/ImapMail" ]; then
    echo "FAIL: read -ra hat '*/ImapMail' zu '${FIXED_ARR[1]}' expandiert (sollte literal bleiben)." >&2
    FAIL=1
fi

# Gegenprobe: die alte, kaputte Variante MUSS unter denselben Bedingungen
# tatsächlich falsch expandieren - sonst würde dieser Test gar nichts prüfen.
OLD_BROKEN_ARR=()
# shellcheck disable=SC2206  # bewusst die alte, unsichere Variante zum Vergleich
OLD_BROKEN_ARR=(${EXTRA_ARGS_VALUE})
if [ "${OLD_BROKEN_ARR[1]}" == "*/ImapMail" ]; then
    echo "FAIL: Testaufbau fehlerhaft - die absichtlich kaputte Vergleichsvariante globbt in dieser Umgebung nicht." >&2
    FAIL=1
fi

if [ "${FAIL}" -eq 0 ]; then
    echo "OK: BORG_CREATE_EXTRA_ARGS/PRUNE_RETENTION sind glob-sicher (read -ra statt unquoted expansion)."
fi

exit "${FAIL}"
