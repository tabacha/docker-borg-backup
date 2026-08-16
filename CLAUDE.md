# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash-Skripte + ein `Dockerfile`, die zusammen ein Borg-Backup-Setup bilden: sichert
ein Host-Verzeichnis per [Borg](https://borgbackup.org/) über SSH in ein Remote-Repo
(z.B. Hetzner Storage Box). Borg läuft nicht auf dem Host, sondern in einem
Docker-Container. Es gibt keinen Anwendungscode im klassischen Sinn — die Skripte
sind die Anwendung. Vollständige Nutzungs-/Setup-Doku steht in `README.md`
(insbesondere "Sicherheit: zwei Schlüssel gegen Ransomware" nicht ohne Grund
lesen, bevor an der Auth-Trennung geändert wird), Entwickler-Doku
(CI/Release-Pipeline, lokale Checks) in `DEVELOPMENT.md`.

## Git-Workflow

- **Nie direkt auf `main` pushen.** Immer einen Branch erstellen, darauf
  committen/pushen, PR öffnen.
- Branch-Namen immer mit vorangestelltem Datum: `YYYY-MM-DD_Kurzbeschreibung`,
  z.B. `2026-08-16_Release_Finetuning`.

## Validating changes

Kein klassisches Unit-Test-Framework, aber `.github/scripts/functional-test.sh`
ist ein echter Funktionstest (kompletter Borg-Zyklus inkl. FUSE-Mount gegen
ein lokales Repo) und läuft überall dort, wo auch Docker läuft — nicht nur in
CI:

- Shell-Skripte: `bash -n <script>.sh` für Syntax, dazu
  `shellcheck --severity=warning -- *.sh .github/scripts/*.sh`. Jedes
  Skript sourced dynamisch genau eine `targets/<target>.env` — das braucht
  einen `# shellcheck source=/dev/null` direkt darüber (siehe backup.sh &
  Co.), sonst SC1090 (non-constant source), das anders als das alte SC1091
  bei `.env` (gab's bis v1.0.x) nicht per `--severity` gefiltert wird. Bei
  Änderungen an Subshell-Konstrukten den `set -e`-Fallstrick unten beachten.
- `Dockerfile`: `docker build -t ci-test:local .` dann
  `.github/scripts/functional-test.sh ci-test:local` — testet den ganzen
  Zyklus (`init`/`create`/`list`/`info`/`check`/`extract`/`mount`+FUSE/
  `prune`/`delete`/`compact`), nicht nur `borg --version`. Zusätzlich
  `docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile` (Config in
  `.hadolint.yaml`, DL3008 ist bewusst ignoriert — siehe Kommentar dort).
- `compose.yml`: `SSH_AUTH_SOCK=/tmp/fake docker compose config` — einmal mit
  vorhandener `targets/<name>.env` (Werte per `set -a; source
  targets/<name>.env; set +a` UND `TARGET=<name>` exportieren, `compose.yml`
  lädt `targets/*.env` nicht automatisch), einmal ganz ohne testen (muss
  dann mit einer klaren Fehlermeldung abbrechen — `TARGET`/`BORG_SSH_*` sind
  über `${VAR:?...}` als Pflichtvariablen markiert). **Dafür niemals die
  echten `targets/*.env` im Arbeitsverzeichnis verwenden** — schon einmal
  aus Versehen mit der alten globalen `.env` passiert (dabei die echte
  `.env` überschrieben+gelöscht, nur durch eine frühere `cat .env`-Ausgabe
  im Gesprächsverlauf wieder rekonstruierbar gewesen). Immer in eine
  Scratch-Kopie kopieren, dort testen.
- GitHub-Actions-YAML: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/X.yml'))"`
  für schnelles Parsing, `actionlint` (Docker-Image `rhysd/actionlint:1.7.12`)
  für echte Validierung inkl. Shellcheck der `run:`-Blöcke — braucht ein
  Git-Repo im gemounteten Verzeichnis (`no project was found...` sonst).
- CI-Läufe beobachten: `gh run list --repo tabacha/docker-borg-backup`,
  `gh run watch <id> --repo tabacha/docker-borg-backup --exit-status`.
- Dieses Arbeitsverzeichnis gehört hier `root`, während als anderer User
  gearbeitet wird → `git` verweigert sich wegen "dubious ownership". Nicht
  global `safe.directory` setzen, sondern pro Aufruf:
  `git -c safe.directory=<repo-pfad> <befehl>`.
- `docker run -v "$(pwd):/ziel" ...` auf das eigentliche Repo-Verzeichnis
  kann in manchen Sandbox-Setups mit "mkdir ... file exists" fehlschlagen
  (Bind-Mount-Quirk, kein Bug im Projekt) — betroffene Dateien dann in ein
  Scratch-Verzeichnis kopieren und von dort aus mounten.

## Architecture

### Ein Compose-Service für alles

`compose.yml` definiert nur den Service `borg-admin`. Alle vier Skripte rufen
`docker compose run --rm borg-admin ...` mit unterschiedlichen Argumenten auf,
es gibt keine separaten Services für Backup vs. Admin-Operationen — die
Trennung passiert über *welche Skripte welchen SSH-Key mitbringen*, nicht über
unterschiedliche Container/Images. `compose.yml` braucht dafür die
Umgebungsvariable `TARGET` (`${TARGET:?...}`, harter Fehler wenn nicht
gesetzt) — jedes der vier Skripte exportiert sie aus seinem `<target>`-Arg,
bevor es `docker compose run` aufruft. `admin-shell.sh` sourced
`targets/<target>.env` zusätzlich selbst mit `set -a`, weil `docker compose`
Variablen nur automatisch aus einer Datei namens `.env` lädt (die es hier
nicht mehr gibt), nicht aus `targets/*.env`.

### Config kommt komplett aus `targets/<name>.env` + `secrets/`, nie hartcodiert

Alles Deployment-Spezifische (Storage-Box-Zugangsdaten, Archiv-Präfix,
Push-Tokens, Backup-Quellpfade, Pre-Backup-Hook) steht pro Zielserver in
`targets/<name>.env` (git-ignored; `targets/example.env.example` ist die
Vorlage). Es gibt bewusst KEIN zusätzliches globales `.env` mehr (gab es bis
v1.0.x, wurde entfernt, damit eine Migration/ein neuer Zielserver ein
einziges `cp`/`mv` ist statt zwei Dateien synchron zu halten) — jede
`targets/<name>.env` ist für sich vollständig, auch wenn sich Werte wie
Quellpfade zwischen mehreren Zielservern desselben Hosts dadurch wiederholen
können. Geheimnisse/Keys liegen pro Zielserver in `secrets/<name>/`
(ebenfalls git-ignored). Weder `compose.yml` noch die Skripte dürfen wieder
Werte wie den Storage-Box-Username hartcodieren — genau das wurde bewusst
herausrefactort, damit das Repo öffentlich auf GitHub liegen kann.

Migration von der alten Ein-`.env`-Struktur (v1.0.x): `migrate-to-v1.1.sh
<name>`, siehe README.md → "Migration von v1.0.x auf v1.1.0".

`BASE_DIR` wird in jedem Skript aus dem eigenen Pfad ermittelt
(`$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`), nicht hartcodiert — das
Repo muss aus jedem Klon-Pfad heraus funktionieren.

### Zwei-Schlüssel-Sicherheitsmodell

Das ist die zentrale Design-Entscheidung im Repo (Details: README →
"Sicherheit: zwei Schlüssel gegen Ransomware"). Alle vier Skripte nehmen als
erstes Argument einen Zielserver-Namen (`<target>`, siehe README →
"Mehrere Zielserver") und operieren nur auf dessen Repo:

| Skript | Trigger | Auth |
|---|---|---|
| `backup.sh <target>` | Cron, unbeaufsichtigt | **Backup-Key** aus `secrets/<target>/backup_ed25519` — baut sich pro Lauf einen eigenen `ssh-agent` auf und killt ihn per `trap ... EXIT` garantiert wieder. Soll serverseitig auf Append-Only beschränkt sein. |
| `admin-compact.sh <target>` | Manuell, `ssh -A` | **Admin-Key** — existiert absichtlich NIE als Datei in `secrets/` oder sonst im Repo, sondern muss per Agent-Forwarding (`SSH_AUTH_SOCK`) mitgebracht werden. |
| `admin-shell.sh <target>` | Manuell, `ssh -tA` (echtes TTY nötig) | Admin-Key wie oben. |
| `disaster-recovery-info.sh <target>` | Manuell, lokal | Kein SSH nötig — liest nur `targets/<target>.env`/`secrets/<target>/passphrase`/`secrets/<target>/known_hosts` und druckt, spricht nicht mit Docker/Repo-Server. |

Wer diese Skripte ändert: Diese Trennung nicht aufweichen (z.B.
`admin-compact.sh`/`admin-shell.sh` nie einen eigenen Key aus `secrets/`
nehmen lassen — der Witz ist, dass der mächtige Key nie auf dem gesicherten
Host als Datei liegt). Der Admin-Key selbst ist NICHT pro Zielserver
getrennt (er landet ja nie als Datei hier) — ein Admin-`ssh-agent` kann
mehrere Admin-Keys für mehrere Zielserver gleichzeitig vorhalten.

Alle vier Skripte außer `disaster-recovery-info.sh` nehmen denselben `flock`,
aber PRO ZIELSERVER: `/run/lock/docker-borg-backup-<target>.lock` — Backup/
Compact/interaktive Shell für DENSELBEN Zielserver überlappen sich dadurch
nicht, verschiedene Zielserver blockieren sich aber nicht gegenseitig.

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
