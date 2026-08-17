# Development

Für alle, die an diesem Repo selbst arbeiten (Skripte, `Dockerfile`,
CI/Release-Pipeline). Für Aufbau und Betrieb der Backup-Lösung siehe
[README.md](README.md).

## Workflow

- Nie direkt auf `main` pushen. Immer einen Branch erstellen, darauf
  committen/pushen, PR öffnen.
- Branch-Namen immer mit vorangestelltem Datum: `YYYY-MM-DD_Kurzbeschreibung`,
  z.B. `2026-08-16_Release_Finetuning`.

## Lokal testen

Kein klassisches Unit-Test-Framework, dafür ein echter Funktionstest
(`.github/scripts/functional-test.sh`), der überall läuft, wo Docker läuft —
nicht nur in CI. Das ist auch, was `ci.yml`/`release.yml` selbst benutzen,
lokal reproduzierbar:

```bash
# Shell-Syntax + Lint. Jedes Skript sourced dynamisch genau eine
# targets/<target>.env - das braucht einen "# shellcheck source=/dev/null"
# direkt darüber (siehe backup.sh & Co.), sonst SC1090 (non-constant
# source), das anders als SC1091 nicht per --severity=warning gefiltert
# wird:
bash -n *.sh .github/scripts/*.sh
shellcheck --severity=warning -- *.sh .github/scripts/*.sh

# Dockerfile-Lint (Konfiguration in .hadolint.yaml, DL3008 ist bewusst
# ignoriert - siehe Kommentar dort):
docker run --rm -i hadolint/hadolint:v2.15.1 < Dockerfile

# Workflow-YAML (inkl. Shellcheck der run:-Blöcke):
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:1.7.12 -color

# compose.yml: einmal mit vorhandener targets/<name>.env, einmal ganz ohne
# (muss dann sauber abbrechen statt mit leeren Werten durchzulaufen).
# NICHT gegen die echten targets/*.env laufen lassen, sondern in einer
# Kopie testen.
cp targets/example.env.example targets/example.env
set -a && source targets/example.env && set +a
TARGET=example SSH_AUTH_SOCK=/tmp/fake docker compose config

# Image + kompletter Borg-Zyklus (init/create/list/info/check/extract/
# mount+FUSE/prune/delete/compact) gegen ein lokales Repo, kein SSH nötig:
docker build -t ci-test:local .
.github/scripts/functional-test.sh ci-test:local
```

CI-Läufe beobachten: `gh run list --repo tabacha/docker-borg-backup`,
`gh run watch <id> --repo tabacha/docker-borg-backup --exit-status`.

## CI & Releases

Zwei Workflows unter `.github/workflows/`:

- **`ci.yml`** — läuft bei jedem Push auf `main` und jedem Pull Request:
  - Job `lint`: `shellcheck` (alle `*.sh`), `hadolint` (`Dockerfile`,
    Konfiguration in `.hadolint.yaml`), `actionlint` (die Workflow-Dateien
    selbst, inkl. Shellcheck der `run:`-Blöcke), `docker compose config`
    einmal mit und einmal ohne `targets/<name>.env` (muss im zweiten Fall
    sauber fehlschlagen).
  - Job `build-and-test`: baut das Image und lässt
    `.github/scripts/functional-test.sh` drüberlaufen — kompletter
    Borg-Zyklus (`init`/`create`/`list`/`info`/`check`/`extract`/`mount`
    inkl. echtem FUSE-Mount/`prune`/`delete`/`compact`) gegen ein lokales
    Repo, kein SSH nötig.
- **`release.yml`** — baut das Image, lässt **dasselbe**
  `functional-test.sh` gegen den lokal geladenen Build laufen, und pusht
  erst bei Erfolg nach [GHCR](https://ghcr.io/tabacha/docker-borg-backup)
  (Build-Cache vom Testlauf wird wiederverwendet, der zweite Build für den
  Push ist entsprechend schnell). Danach automatisch ein GitHub Release.
  Getriggert durch einen Tag der Form `vX.Y.Z`. Ein Release machen:

  ```bash
  git tag v1.0.0
  git push origin v1.0.0
  ```

  Das Image landet dann als `ghcr.io/tabacha/docker-borg-backup:1.0.0`,
  `:1.0` und `:latest`.

  **Pre-Release:** Ein Tag mit Bindestrich-Suffix (Semver-Konvention für den
  Prerelease-Teil, z.B. `v1.1.0-rc1`) triggert `release.yml` genauso — baut
  also inkl. komplettem `functional-test.sh`-Zyklus via echter CI und pusht
  bei Erfolg —, setzt aber NUR den exakten Versions-Tag (`1.1.0-rc1`).
  Weder `:1.1` noch `:latest` werden dabei (um)gesetzt, ein Tag der Form
  `vX.Y.Z-irgendwas` überschreibt also nie den Tag, den ein normales
  `docker compose pull` zieht. Die GitHub Release wird dafür automatisch als
  "Pre-release" markiert (`prerelease: true`), taucht also auch dort nicht
  als "Latest release" auf. Kann also z.B. zum Testen des kompletten
  Release-Workflows für einen noch nicht gemergten Branch genutzt werden,
  ohne `main`/produktive Nutzer zu beeinflussen — Tag zeigt dabei einfach
  auf den zu testenden Commit, unabhängig vom Branch:

  ```bash
  git tag v1.1.0-rc1 <commit-oder-branch>
  git push origin v1.1.0-rc1
  ```

  Nicht mehr gebrauchte Pre-Release-Tags danach wieder aufräumen (Tag +
  GitHub Release + GHCR-Image-Tag jeweils einzeln, `git push --delete` bzw.
  über die GitHub-UI).

  Damit `docker pull` (siehe README.md → Ersteinrichtung) ohne Login
  funktioniert, muss das Package einmalig auf **Public** gestellt werden:
  auf GitHub zum Repo → rechte Seitenleiste unter "Packages" auf das
  Package klicken → **Package settings** → ganz unten
  **Change visibility** → **Public**. Ohne diesen Schritt ist das Image
  privat und `docker pull`/`docker compose pull` bräuchten vorher
  `docker login ghcr.io`.

## Sonstiges (intern)

- Ohne gesetztes `SSH_AUTH_SOCK` (z.B. bei reinem `docker compose build`)
  fällt `compose.yml` auf einen Platzhalter-Pfad zurück, damit der Build
  nicht an einem leeren Volume-Mount scheitert.
- `docker run -v "$(pwd):/ziel" ...` kann in manchen Sandbox-/CI-Setups mit
  "mkdir ... file exists" fehlschlagen (Bind-Mount-Quirk, kein Bug im
  Projekt) — betroffene Dateien dann in ein Scratch-Verzeichnis kopieren
  und von dort aus mounten.
