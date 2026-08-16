# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash-Skripte + ein `Dockerfile`, die zusammen ein Borg-Backup-Setup bilden: sichert
ein Host-Verzeichnis per [Borg](https://borgbackup.org/) über SSH in ein Remote-Repo
(z.B. Hetzner Storage Box). Borg läuft nicht auf dem Host, sondern in einem
Docker-Container. Es gibt keinen Anwendungscode im klassischen Sinn — die Skripte
sind die Anwendung. Vollständige Nutzungs-/Setup-Doku steht in `README.md`, dort
insbesondere die Abschnitte "Sicherheit: zwei Schlüssel gegen Ransomware" und
"CI & Releases" nicht ohne Grund lesen, bevor an der Auth-Trennung oder der
Release-Pipeline geändert wird.

## Git-Workflow

- **Nie direkt auf `main` pushen.** Immer einen Branch erstellen, darauf
  committen/pushen, PR öffnen.
- Branch-Namen immer mit vorangestelltem Datum: `YYYY-MM-DD_Kurzbeschreibung`,
  z.B. `2026-08-16_Release_Finetuning`.

## Validating changes (keine Testsuite)

- Shell-Skripte: `bash -n <script>.sh` für Syntax, danach gegenlesen. Alle Skripte
  laufen mit `set -Eeuo pipefail`/`set -euo pipefail` — bei Änderungen an
  Subshell-Konstrukten den `set -e`-Fallstrick unten beachten.
- `compose.yml`: `SSH_AUTH_SOCK=/tmp/fake docker compose config` — einmal mit
  vorhandener `.env`, einmal mit umbenannter/fehlender `.env` testen (muss dann
  mit einer klaren Fehlermeldung abbrechen, nicht mit leeren Werten durchlaufen).
- GitHub-Actions-YAML: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/X.yml'))"`.
- CI-Läufe beobachten: `gh run list --repo tabacha/docker-borg-backup`,
  `gh run watch <id> --repo tabacha/docker-borg-backup --exit-status`.
- Dieses Arbeitsverzeichnis gehört hier `root`, während als anderer User
  gearbeitet wird → `git` verweigert sich wegen "dubious ownership". Nicht
  global `safe.directory` setzen, sondern pro Aufruf:
  `git -c safe.directory=<repo-pfad> <befehl>`.

## Architecture

### Ein Compose-Service für alles

`compose.yml` definiert nur den Service `borg-admin`. Alle vier Skripte rufen
`docker compose run --rm borg-admin ...` mit unterschiedlichen Argumenten auf,
es gibt keine separaten Services für Backup vs. Admin-Operationen — die
Trennung passiert über *welche Skripte welchen SSH-Key mitbringen*, nicht über
unterschiedliche Container/Images.

### Config kommt komplett aus `.env` + `secrets/`, nie hartcodiert

Alles Deployment-Spezifische (Storage-Box-Zugangsdaten, Archiv-Präfix,
Push-Tokens, Backup-Quellpfad) steht in `.env` (git-ignored; `.env.example`
ist die Vorlage). Geheimnisse/Keys liegen in `secrets/` (ebenfalls
git-ignored). Weder `compose.yml` noch die Skripte dürfen wieder Werte wie den
Storage-Box-Username hartcodieren — genau das wurde bewusst herausrefactort,
damit das Repo öffentlich auf GitHub liegen kann.

`BASE_DIR` wird in jedem Skript aus dem eigenen Pfad ermittelt
(`$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`), nicht hartcodiert — das
Repo muss aus jedem Klon-Pfad heraus funktionieren.

### Zwei-Schlüssel-Sicherheitsmodell

Das ist die zentrale Design-Entscheidung im Repo (Details: README →
"Sicherheit: zwei Schlüssel gegen Ransomware"):

| Skript | Trigger | Auth |
|---|---|---|
| `backup.sh` | Cron, unbeaufsichtigt | **Backup-Key** aus `secrets/backup_ed25519` — baut sich pro Lauf einen eigenen `ssh-agent` auf und killt ihn per `trap ... EXIT` garantiert wieder. Soll serverseitig auf Append-Only beschränkt sein. |
| `admin-compact.sh` | Manuell, `ssh -A` | **Admin-Key** — existiert absichtlich NIE als Datei in `secrets/` oder sonst im Repo, sondern muss per Agent-Forwarding (`SSH_AUTH_SOCK`) mitgebracht werden. |
| `admin-shell.sh` | Manuell, `ssh -tA` (echtes TTY nötig) | Admin-Key wie oben. |
| `disaster-recovery-info.sh` | Manuell, lokal | Kein SSH nötig — liest nur `.env`/`secrets/passphrase`/`secrets/known_hosts` und druckt, spricht nicht mit Docker/Repo-Server. |

Wer diese Skripte ändert: Diese Trennung nicht aufweichen (z.B.
`admin-compact.sh`/`admin-shell.sh` nie einen eigenen Key aus `secrets/`
nehmen lassen — der Witz ist, dass der mächtige Key nie auf dem gesicherten
Host als Datei liegt).

Alle vier Skripte außer `disaster-recovery-info.sh` nehmen denselben `flock`
auf `/run/lock/docker-borg-backup.lock`, damit sich Backup/Compact/interaktive
Shell nicht überlappen.

### `set -e`-Fallstrick in `admin-compact.sh`

`VAR=$(subshell-mit-eigenem-set-e)` bricht unter einem äußeren `set -e` das
Skript sofort ab, sobald die Subshell nicht-null exitet — `$?` danach wird nie
ausgewertet. `if VAR=$(...); then ... else ...; fi` behebt das scheinbar,
unterdrückt dabei aber überraschend auch das `set -e` *innerhalb* der
Subshell (getestet, verworfen). Der tatsächlich funktionierende Fix in
`admin-compact.sh`: `set +e` / `set -e` explizit um die Zuweisung herum.
`backup.sh` braucht den Trick nicht, weil dort kein Subshell involviert ist —
dort reicht `if docker compose ...; then RC=0; else RC=$?; fi`.

### CI/Release-Pipeline (`.github/workflows/`)

- `docker-build.yml`: Trigger nur `push: branches: [main]` + Pfadfilter auf
  `Dockerfile`. Baut nur, pusht nichts. Bewusst OHNE Tag-Trigger — sonst läuft
  er bei jedem Release-Tag doppelt mit `release.yml` mit (GitHub zählt bei
  einem neuen Tag alle Dateien des Commits als "geändert", der Pfadfilter
  schlägt dann fälschlich auch hier an).
- `release.yml`: Trigger `push: tags: v*.*.*`. Baut + pusht nach
  `ghcr.io/tabacha/docker-borg-backup`, taggt `X.Y.Z` / `X.Y` / `latest`.
  `docker/metadata-action` schneidet das `v`-Prefix vom Git-Tag beim Taggen
  ab — bei Referenzen auf den tatsächlichen Image-Tag in generiertem Text
  `steps.meta.outputs.version` benutzen, nicht `github.ref_name` (war schon
  mal falsch in der Release-Beschreibung).
- GHCR-Package-Sichtbarkeit ist eine vom Repo getrennte Einstellung und muss
  manuell in den Package-Settings auf Public gestellt werden, damit
  `docker compose pull` ohne Login funktioniert.
- Action-Versionen aktuell halten (Node-20-Deprecation-Warnungen sind ein
  zuverlässiges Signal, dass eine Major-Version-Anhebung ansteht) —
  `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'` zeigt die
  aktuelle Version.

## Sprache

Kommentare, Doku (README, Skript-Ausgaben, Commit-Messages, Release-Notes)
sind durchgehend Deutsch — dabei bleiben.
