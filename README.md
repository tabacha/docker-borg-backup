# docker-borg-backup

> Dieses Projekt wurde mit KI-Unterstützung (Claude Code) erstellt. Ich habe
> alles grob gereviewt, aber nicht jede Zeile im Detail geprüft — bei
> sicherheitsrelevanten Teilen (siehe unten) selbst nochmal genau hinschauen,
> bevor du das produktiv einsetzt.

Sichert ein Host-Verzeichnis per [Borg](https://borgbackup.org/) über SSH in ein
Remote-Repo (z.B. eine Hetzner Storage Box). Borg läuft dabei nicht auf dem Host
selbst, sondern in einem Docker-Container, gebaut aus dem `Dockerfile` in diesem
Repo.

## Verzeichnisstruktur

| Pfad                | Zweck                                                              |
|----------------------|--------------------------------------------------------------------|
| `Dockerfile`          | Baut das Borg-Image, inkl. FUSE-Support.      |
| `compose.yml`         | Ein Service `borg-admin`, den alle Skripte via `docker compose run` benutzen. Braucht die Umgebungsvariable `TARGET` (welcher Zielserver, siehe unten), die alle Skripte selbst setzen. Image kommt vorgebaut von GHCR (`docker compose pull`), `build: .` ist Fallback. |
| `DEVELOPMENT.md`      | Für Mitarbeit am Repo selbst: lokale Checks, CI/Release-Pipeline.   |
| `targets/` / `targets/example.env.example` | Pro Zielserver eine vollständige `targets/<name>.env` (Repo-Zugang, Quellpfade, Hook, Retention, Uptime-Kuma, …) — mehrere Dateien für mehrere unabhängige Zielserver, kein zusätzliches globales `.env`. Siehe [Mehrere Zielserver](#mehrere-zielserver). |
| `secrets/`            | Pro Zielserver ein Unterverzeichnis `secrets/<name>/` mit eigenem SSH-Key, `known_hosts`, Repo-Passphrase. Pro Host eigen, siehe unten. |
| `setup-secrets.sh`    | Befüllt `secrets/<target>/` für EINEN Zielserver (idempotent). Läuft auf dem Host oder im Container. |
| `migrate-to-v1.1.sh`  | Einmalige Migrationshilfe von v1.0.x (eine globale `.env`) auf v1.1.0+ (benannte Zielserver). Siehe [Migration](#migration-von-v10x-auf-v110). |
| `backup.sh`           | Unbeaufsichtigter Backup-Lauf für EINEN Zielserver, für Cron gedacht. |
| `admin-compact.sh`    | Retention (`prune`) + `compact` für EINEN Zielserver, interaktiv per SSH-Login. |
| `admin-shell.sh`      | Interaktive Shell im Container für EINEN Zielserver — Restore, `borg mount`, Ad-hoc-Kommandos. |
| `disaster-recovery-info.sh` | Druckt ein Notfall-Blatt (Repo-Adresse + Passphrase + Restore-Anleitung) für EINEN Zielserver, für den Fall, dass dieser Host mal komplett weg ist. |
| `restore/`            | Wird nach `/restore` in den Container gemountet, landet dort Extrahiertes. |
| `logs/`               | Logs aller Skript-Läufe (pro Zielserver eigene Dateien), wird automatisch nach 30 Tagen bereinigt. |

## Ersteinrichtung

1. **Repo klonen**, egal wohin — die Skripte finden ihr eigenes Verzeichnis
   selbst (`BASE_DIR` wird aus dem Skriptpfad ermittelt).

   ```bash
   git clone git@github.com:tabacha/docker-borg-backup.git
   ```

2. **Zielserver anlegen.** Für jeden Zielserver, zu dem gesichert werden
   soll, eine vollständige `targets/<name>.env` — das ist die einzige
   Konfigurationsdatei, kein zusätzliches globales `.env`:

   ```bash
   cp targets/example.env.example targets/hetzner1.env
   ```

   `<name>` ist frei wählbar (nur Buchstaben/Ziffern/`-`/`_`) und der
   Bezeichner, mit dem alle Skripte diesen Zielserver ansprechen — siehe
   [Mehrere Zielserver](#mehrere-zielserver). Und ausfüllen:

   | Variable                    | Bedeutung                                                        |
   |------------------------------|-------------------------------------------------------------------|
   | `BORG_SSH_USER/_HOST/_PORT`  | SSH-Zugang zu diesem Zielserver.                                  |
   | `BORG_REPO_PATH`             | Pfad des Repos auf dem Server (z.B. `./borg-backup`).             |
   | `BORG_REMOTE_PATH`           | Name des Borg-Server-Binaries auf dem Remote (Hetzner braucht z.B. `borg-1.4`). |
   | `ARCHIVE_PREFIX`             | Präfix der Archivnamen (`::<prefix>-<zeitstempel>`), auch Filter fürs Prune. |
   | `BACKUP_SOURCE_DIRS`         | Host-Verzeichnis(se), die zu diesem Zielserver gesichert werden (`-> /source/<n>` im Container). Mehrere unabhängige Verzeichnisbäume durch Leerzeichen getrennt. |
   | `BORG_CREATE_EXTRA_ARGS`     | Zusätzliche `borg create`-Flags (z.B. `--exclude-caches`, `--numeric-owner`). Optional. |
   | `PRE_BACKUP_HOOK`            | Befehl, der auf dem Host vor `borg create` läuft (z.B. `mongodump`). Optional, bricht den Lauf bei Fehlschlag ab. |
   | `PRUNE_RETENTION`            | Retention-Flags für `borg prune` in `admin-compact.sh`. Optional — auskommentiert lassen übernimmt den Default im Skript. |
   | `UPTIME_KUMA_*`              | Push-Monitor für Backup und Compact DIESES Zielservers. Optional — leer lassen deaktiviert den Push komplett, es wird dann gar kein Request gemacht. |

   Sichert derselbe Host dieselben Pfade zu mehreren Zielservern, wiederholen
   sich Werte wie `BACKUP_SOURCE_DIRS` zwangsläufig in mehreren
   `targets/*.env` — das ist so gewollt: jede Datei ist für sich vollständig
   und eigenständig kopierbar/verschiebbar.

3. **`secrets/<name>/` befüllen.** Diese Dateien werden NICHT
   geteilt/committet (siehe `.gitignore`), jeder Deployment-Host UND jeder
   Zielserver braucht eigene:

   - `backup_ed25519` / `.pub` — SSH-Keypaar für den unbeaufsichtigten
     Backup-Lauf zu diesem Zielserver (`backup.sh <name>`). Das ist der
     **Backup-Key** — mehr dazu und warum der eingeschränkte Rechte
     bekommen sollte im Abschnitt
     [Sicherheit: zwei Schlüssel](#sicherheit-zwei-schlüssel-gegen-ransomware)
     weiter unten.
   - `known_hosts` — SSH-Hostkey dieses Zielservers.
   - `passphrase` — Borg-Repo-Passphrase für dieses Zielserver-Repo, eine
     Zeile.

   `setup-secrets.sh <name>` erledigt das für EINEN Zielserver (idempotent
   — was schon da ist, bleibt unangetastet, beliebig oft erneut ausführbar,
   braucht die zugehörige `targets/<name>.env` aus Schritt 2):

   ```bash
   ./setup-secrets.sh hetzner1
   ```

   Läuft auch ohne `ssh-keygen`/`ssh-keyscan` auf dem Host und sogar ganz
   ohne Repo-Klon, nur mit `targets/<name>.env` im aktuellen Verzeichnis —
   das Skript liegt im Image fest unter `/usr/local/bin/setup-secrets.sh`:

   ```bash
   docker run --rm -v "$(pwd):/work" -e BASE_DIR=/work \
       --entrypoint /usr/local/bin/setup-secrets.sh \
       ghcr.io/tabacha/docker-borg-backup:latest hetzner1
   ```

   Den ausgegebenen Public Key (`secrets/hetzner1/backup_ed25519.pub`) beim
   Repo-Provider hinterlegen. Für weitere Zielserver Schritt 2+3 wiederholen.

4. **Externe Docker-Volumes anlegen** (Cache/Config bleiben so über
   Image-Updates hinweg erhalten, gemeinsam für alle Zielserver — siehe
   [Mehrere Zielserver](#mehrere-zielserver)):

   ```bash
   docker volume create docker-borg-backup_borg-cache
   docker volume create docker-borg-backup_borg-config
   ```

5. **Image holen** (fertig gebaut von GHCR, spart den lokalen Build):

   ```bash
   docker compose pull
   ```

   Alternativ selbst bauen (z.B. für lokale Änderungen am `Dockerfile`):

   ```bash
   docker compose build
   ```

6. **Borg-Repo(s) einmalig initialisieren** (nur beim allerersten Mal, für
   ein neues/leeres Repo, pro Zielserver einmal). Das ist eine
   Admin-Operation, braucht also den Admin-Key per Agent-Forwarding — am
   einfachsten direkt in `admin-shell.sh` (siehe unten, `ssh -tA
   user@host /pfad/zum/repo/admin-shell.sh hetzner1`) und dort:

   ```bash
   borg init --encryption=repokey-blake2
   ```

   Alternativ auch von außen möglich, dann aber selbst für ein gesetztes
   `TARGET` sowie ein `SSH_AUTH_SOCK` mit Zugriff auf den Repo-Server sorgen:

   ```bash
   TARGET=hetzner1 docker compose run --rm borg-admin init --encryption=repokey-blake2
   ```

## Mehrere Zielserver

Alle vier Betriebsskripte (`backup.sh`, `admin-compact.sh`, `admin-shell.sh`,
`disaster-recovery-info.sh`) nehmen als erstes Argument einen
Zielserver-Namen entgegen und operieren dann NUR auf dessen Repo — sinnvoll,
wenn z.B. zu mehreren wechselnd erreichbaren Admin-Rechnern zuhause parallel
gesichert werden soll (statt zu genau einem fest verdrahteten Server).

Jeder Zielserver hat eine eigene, vollständige `targets/<name>.env`
(Zugangsdaten, Quellpfade, Hook, Retention, Uptime-Kuma — kein gemeinsames
globales `.env`) und ein eigenes `secrets/<name>/` (eigener Backup-Key,
eigene `known_hosts`, eigene Repo-Passphrase) — ein kompromittierter
Backup-Key für Zielserver A gibt also keinen Zugriff auf das Repo von
Zielserver B. Cache- und Config-Volume
(`docker-borg-backup_borg-cache`/`_borg-config`) werden dagegen gemeinsam
genutzt, das ist unproblematisch: Borg trennt intern nach Repo-ID.

Für regelmäßige Backups zu mehreren Zielservern einfach mehrere Cron-Zeilen
eintragen (siehe unten, `backup.sh <name>`) — jeder Lauf ist unabhängig,
hält aber einen pro Zielserver eigenen Lock, blockiert sich also nicht
gegenseitig. Ein "automatisch den nächsten erreichbaren nehmen"-Failover
gibt es bewusst nicht: welcher Zielserver drankommt, wird explizit beim
Aufruf angegeben, nicht implizit erraten.

## Laufender Betrieb

### Automatisches Backup — `backup.sh`

Für Cron gedacht, z.B. täglich nachts, mit dem Zielserver-Namen aus
`targets/<name>.env` als Argument (siehe
[Mehrere Zielserver](#mehrere-zielserver); für mehrere Zielserver einfach
mehrere Zeilen):

```
0 3 * * * /pfad/zum/repo/backup.sh hetzner1
```

- Baut sich selbst einen SSH-Agent auf, lädt
  `secrets/<target>/backup_ed25519`, entlädt ihn am Ende garantiert wieder
  (auch bei Fehlern).
- Läuft komplett still (`exec >logfile 2>&1`), meldet Erfolg/Fehler nur per
  Uptime-Kuma-Push und Exit-Code.
- Verhindert Überlappung über einen `flock` auf
  `/run/lock/docker-borg-backup-<target>.lock` — läuft für DIESEN
  Zielserver schon ein Backup oder `admin-compact.sh`, beendet sich ein
  zweiter Lauf still mit Exit 0. Verschiedene Zielserver blockieren sich
  dabei nicht gegenseitig.
- Sichert alle in `BACKUP_SOURCE_DIRS` konfigurierten Pfade (einer oder
  mehrere, durch Leerzeichen getrennt) — jeder landet unter `source/<n>/`
  im Archiv, `n` fortlaufend in der angegebenen Reihenfolge.
- Optionaler `PRE_BACKUP_HOOK` (z.B. `mongodump` vor dem Sichern einer
  laufenden MongoDB/Rocket.Chat-Instanz) läuft auf dem Host, direkt vor
  `borg create`. Schlägt er fehl, wird `borg create` übersprungen und der
  Lauf gilt als fehlgeschlagen (Exit-Code + Uptime-Kuma-Push melden das).
- Optionale `BORG_CREATE_EXTRA_ARGS` werden zusätzlich an `borg create`
  angehängt (z.B. `--exclude-caches`, `--numeric-owner`, `--noatime`,
  andere `--compression`).
- Logs unter `logs/backup-<target>-<zeitstempel>.log`, 30 Tage Aufbewahrung.

### Wartung — `admin-compact.sh`

Retention (`prune`) + `compact`, macht das Repo nicht kleiner, wenn man's
nicht regelmäßig laufen lässt. Braucht einen per SSH weitergereichten
Agent, Argument wie bei `backup.sh` der Zielserver-Name:

```bash
ssh -A user@host /pfad/zum/repo/admin-compact.sh hetzner1
```

- Bricht ab, wenn `SSH_AUTH_SOCK` fehlt (`ssh -A` vergessen) oder für
  diesen Zielserver gerade ein Backup/Compact läuft (gleicher Lock wie
  `backup.sh`, siehe oben).
- Zeigt Archive vorher/nachher, wendet die Retention an (Default
  `--keep-within 2d --keep-daily 7 --keep-weekly 3 --keep-monthly 12
  --keep-yearly 2`, per `PRUNE_RETENTION` in `targets/<name>.env`
  konfigurierbar, siehe `targets/example.env.example`), kompaktiert danach.
- Ausgabe geht aufs Terminal UND nach
  `logs/admin-compact-<target>-<zeitstempel>.log`.
- Uptime-Kuma-Push wie beim Backup.

### Interaktive Shell — `admin-shell.sh`

Für alles, was man selten braucht: einzelne Dateien wiederherstellen, ein
Archiv löschen, nach alten Dateien suchen. Braucht ein echtes TTY, Argument
wieder der Zielserver-Name:

```bash
ssh -tA user@host /pfad/zum/repo/admin-shell.sh hetzner1
```

- Landet in einer Bash direkt im Borg-Container, `BORG_REPO` /
  `BORG_PASSCOMMAND` / `BORG_RSH` sind schon gesetzt — `borg` also ohne
  Repo-Pfad aufrufen. Spricht mit dem Repo des angegebenen Zielservers.
- Gibt beim Start eine Kommando-Übersicht aus (list/info/diff/extract/mount/
  delete/prune --dry-run/compact).
- **Restore:** vorher `cd /restore`, dann `borg extract ::<archiv> [pfad]` —
  landet unter `restore/` auf dem Host. Ohne den `cd` landen extrahierte
  Dateien nur im (ephemeren) Container und sind beim Beenden weg.
- **Suchen ohne Extrahieren:** `borg mount ::<archiv> /mnt/borg`, danach
  `find`/`grep` drin, danach `borg umount /mnt/borg` nicht vergessen. Erster
  Mount pro Archiv kann mangels Fortschrittsanzeige mehrere Minuten dauern
  (Borg baut die komplette Item-Liste ins RAM) — das ist normal, kein Hänger.
  Schneller: gleich einen Pfad mitmounten (`borg mount ::<archiv> /mnt/borg
  <pfad>`).
- Hält denselben (zielserver-eigenen) Lock wie Backup/Compact, solange die
  Shell offen ist.
- Komplette Sitzung (Befehle + Ausgabe) wird nach
  `logs/admin-shell-<target>-<zeitstempel>.log` mitgeschnitten.
- Container wird beim Verlassen (`exit`) automatisch entfernt (`--rm`).

## Sicherheit: zwei Schlüssel gegen Ransomware

`backup.sh` benutzt pro Zielserver genau einen SSH-Key
(`secrets/<target>/backup_ed25519`), der unverschlüsselt als Datei auf dem
Host liegt, der gesichert wird. Das ist der klassische Single-Point-of-Failure
bei Backups: Wird der Host kompromittiert, hat der Angreifer auch den
Schlüssel zum Backup-Repo — und kann die Backups löschen, bevor er die
eigentlichen Daten verschlüsselt. Bei mehreren Zielservern gilt das
unabhängig für jeden: Der Backup-Key von Zielserver A gibt keinen Zugriff auf
das Repo von Zielserver B (eigene Secrets pro Zielserver, siehe
[Mehrere Zielserver](#mehrere-zielserver)) — kompromittiert ein Angreifer den
Host, verliert er trotzdem nur die Repos, für die es hier überhaupt einen
Backup-Key gibt.

Das ist kein theoretisches Szenario. Moderne Ransomware löscht routinemäßig
Schattenkopien (`vssadmin delete shadows`), killt Backup-Agenten (Veeam,
Acronis, …) als Prozess und geht gezielt auch erreichbare Netzlaufwerke/NAS-
Freigaben mit an — ein Opfer mit intaktem Backup zahlt schließlich nicht. Das
eindrücklichste Beispiel dafür, wie viel eine wirklich unantastbare Kopie wert
ist, ist genau genommen kein Ransomware-, sondern ein Wiper-Fall: **NotPetya
2017 bei Maersk.** Der Wurm legte praktisch die komplette globale IT lahm,
inklusive aller rund 150 Domain Controller — die sich brav untereinander
synchronisiert hatten, was beim gleichzeitigen Wischen aller Knoten aus einem
verteilten Backup ein verteiltes Nichts macht. Die Rückkehr zum Betrieb
verdankte Maersk einem einzigen Domain Controller in einer Zweigstelle in
Ghana, der zufällig wegen eines Stromausfalls offline war und deshalb nicht
infiziert wurde — ohne diesen einen Zufalls-Ausfall hätte Maersk ihr
komplettes Active Directory nicht rekonstruieren können ([Wired: "The Untold
Story of NotPetya"](https://www.wired.com/story/notpetya-cyberattack-ukraine-russia-code-crashed-the-world/)).

Borg hat für genau dieses Szenario einen eingebauten Schutz: den
[Append-Only-Modus](https://borgbackup.readthedocs.io/en/stable/usage/notes.html#append-only-mode-forbid-compaction).
Ein Repo bzw. der `borg serve`-Prozess auf der Serverseite lässt sich so
einschränken, dass ein Client zwar neue Archive schreiben, aber bestehende
Daten weder überschreiben noch physisch löschen kann. `borg delete`/`borg
prune` laufen technisch weiter durch, hinterlassen aber nur einen
Löschvermerk im Transaktionslog — die Daten selbst bleiben liegen, bis jemand
mit vollem Zugriff `borg compact` ausführt und den Platz wirklich freigibt.

Daraus folgt die empfohlene Aufteilung in **zwei Keys**:

| Key | Liegt wo | Rechte | Genutzt von |
|---|---|---|---|
| **Backup-Key** (`secrets/<target>/backup_ed25519`, einer PRO Zielserver) | Als Datei auf dem gesicherten Host (unvermeidbar für unbeaufsichtigten Cron-Betrieb) | Nur **append-only**: neue Archive schreiben, nichts endgültig löschen | `backup.sh <target>` |
| **Admin-Key** | NUR im eigenen SSH-Agent des Admins (per `ssh -A`/`ssh -tA` weitergereicht) — landet nie als Datei auf dem gesicherten Host. Ein Agent kann mehrere Admin-Keys für mehrere Zielserver gleichzeitig vorhalten, SSH probiert beim Connect passend durch. | Voll: `prune`, `compact`, `delete` | `admin-compact.sh <target>`, `admin-shell.sh <target>` |

Die zweite Hälfte ist in diesem Repo schon eingebaut: `admin-compact.sh` und
`admin-shell.sh` nehmen absichtlich keinen eigenen Key aus `secrets/`, sondern
verlangen ein per Agent-Forwarding mitgebrachtes `SSH_AUTH_SOCK` — der
Admin-Key existiert also nie als Datei auf diesem Host. Noch ein Stück
sicherer wird das, wenn der Admin-Key auf einem YubiKey (oder einem anderen
FIDO2/PIV-Hardwaretoken) liegt: Das private Schlüsselmaterial verlässt dann
nie den Chip, ist auch für den Admin selbst nicht exportierbar, und jede
Nutzung braucht eine physische Berührung des Tokens — ein gestohlener Laptop
oder eine kompromittierte Workstation reicht dann allein nicht mehr, um den
Admin-Key zu benutzen. Was noch fehlt, ist die serverseitige Einschränkung
des Backup-Keys auf Append-Only:

- **Generischer SSH-Server:** Forced Command in `authorized_keys` auf dem
  Repo-Server, vor dem Public Key des Backup-Keys. Das aufgerufene Binary
  muss zu `BORG_REMOTE_PATH` aus `targets/<name>.env` passen (dort meist
  einfach `borg`, bei Hetzner z.B. `borg-1.4` — `setup-secrets.sh <name>`
  gibt die fertige Zeile passend zu diesem Zielserver mit aus):
  ```
  command="borg serve --append-only --restrict-to-repository /pfad/zum/repo",restrict ssh-ed25519 AAAA... borg-backup
  ```
  `restrict` deaktiviert nebenbei Port-Forwarding/PTY/Agent-Forwarding für
  genau diesen Key.
- **Hetzner Storage Box:** Append-Only wird
  [offiziell unterstützt](https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/) —
  dafür ein eigenes Sub-Konto nur für den Backup-Key anlegen und dort
  Append-Only aktivieren. Laut Hetzners eigener Doku kann ein eingeschränkter
  Client `delete`/`prune` weiterhin *anstoßen*, die tatsächliche Löschung wird
  aber zurückgehalten, bis sie von einem unrestricted Client — unserem
  Admin-Key via `admin-compact.sh` — kompaktiert wird. Genau das wollen wir.

Ohne diese serverseitige Einschränkung ist der Backup-Key faktisch genauso
mächtig wie der Admin-Key — die Trennung der beiden Skripte allein schützt
noch nicht vor einem kompromittierten Backup-Host. Das ist der fehlende
letzte Schritt, und der passiert bewusst außerhalb dieses Repos (beim
Repo-Provider), weil genau das den Witz an der Sache ausmacht: Der Host, der
gesichert wird, darf diese Einschränkung nicht selbst aufheben können.

## Notfallwiederherstellung — `disaster-recovery-info.sh`

Wenn dieser Host komplett weg ist (Hardware-Defekt, der Ransomware-Fall von
oben, …), sind `targets/` und `secrets/` genauso weg. Übrig bleibt
bestenfalls ein privater SSH-Key, den jemand getrennt aufbewahrt hat
(Passwort-Tresor, USB-Stick im Safe, …) — aber ein Key allein bringt nichts
ohne die Repo-Adresse und die Passphrase.

Ein Blatt gilt für GENAU EINEN Zielserver — bei mehreren Zielservern für
jeden eins erzeugen. `disaster-recovery-info.sh <target>` liest
`targets/<target>.env` + `secrets/<target>/passphrase` +
`secrets/<target>/known_hosts` und druckt daraus ein einziges, in sich
geschlossenes Blatt: fertige `BORG_REPO`/`BORG_RSH`/`BORG_PASSPHRASE`-Werte
zum Copy-Paste, den SSH-Hostkey zum Pinnen, und zwei komplette
Restore-Anleitungen (mit reinem `pip install borgbackup` ganz ohne Docker,
und mit diesem Repo). Es spricht dabei nicht mit Docker oder dem Repo-Server
und schreibt bewusst nichts nach `logs/` — die Ausgabe enthält die
Passphrase im Klartext.

```bash
./disaster-recovery-info.sh hetzner1 > /tmp/recovery-sheet-hetzner1.txt   # dann SOFORT weg von hier:
# ausdrucken + Safe, oder als Secure Note in den Passwort-Tresor, dann
# /tmp/recovery-sheet-hetzner1.txt wieder löschen.
```

Bei jeder Änderung an `targets/<target>.env`/`secrets/<target>/passphrase`/
`secrets/<target>/known_hosts` neu laufen lassen und das alte Blatt für
diesen Zielserver ersetzen.

## Migration von v1.0.x auf v1.1.0

v1.1.0 führt benannte Zielserver ein (siehe oben,
[Mehrere Zielserver](#mehrere-zielserver)) — die bisherige globale `.env`
wird durch eine vollständige `targets/<name>.env` ersetzt, `secrets/` zieht
pro Zielserver in ein Unterverzeichnis um. Am Borg-Repo selbst, an der
Passphrase und an den vorhandenen Archiven ändert sich dabei NICHTS, es
geht nur um lokales Config-/Secrets-Layout auf dem Host.

**Automatisch mit `migrate-to-v1.1.sh <name>`** (empfohlen — `<name>` frei
wählbar, z.B. der bisherige `ARCHIVE_PREFIX`-Wert oder einfach `default`):

```bash
cd /pfad/zum/repo
git pull
./migrate-to-v1.1.sh <name>
```

Macht aus der bestehenden `.env` (per `BACKUP_SOURCE_DIR` →
`BACKUP_SOURCE_DIRS` umbenannt) eine `targets/<name>.env` und verschiebt
`secrets/*` nach `secrets/<name>/`. Lässt die alte `.env` unangetastet
liegen (nur kopiert, nicht verschoben) — nach Kontrolle der neuen
`targets/<name>.env` selbst löschen.

**Von Hand**, falls lieber selbst Schritt für Schritt (macht exakt dasselbe):

```bash
cd /pfad/zum/repo
git pull
mkdir -p secrets/<name>
sed 's/^BACKUP_SOURCE_DIR=/BACKUP_SOURCE_DIRS=/' .env > targets/<name>.env
mv secrets/backup_ed25519 secrets/backup_ed25519.pub secrets/known_hosts secrets/passphrase secrets/<name>/
```

In beiden Fällen danach noch zu erledigen:

1. **Cron-/SSH-Aufrufe um den Zielserver-Namen ergänzen:**

   ```
   0 3 * * * /pfad/zum/repo/backup.sh <name>
   ```
   ```bash
   ssh -A user@host /pfad/zum/repo/admin-compact.sh <name>
   ssh -tA user@host /pfad/zum/repo/admin-shell.sh <name>
   ```

2. **Neues Notfall-Blatt erzeugen** (Pfade darin haben sich geändert, altes
   Blatt danach vernichten):

   ```bash
   ./disaster-recovery-info.sh <name> > /tmp/recovery-sheet-<name>.txt
   ```

3. **Alte `.env` löschen**, sobald `targets/<name>.env` kontrolliert ist:
   `rm .env`.

Alte Lock-Datei (`/run/lock/docker-borg-backup.lock`) und alte Logs
(`logs/backup-<zeitstempel>.log` ohne Zielserver-Namen im Dateinamen)
werden ab jetzt nicht mehr benutzt (neu:
`docker-borg-backup-<name>.lock`/`logs/backup-<name>-<zeitstempel>.log`) —
können unbesorgt liegen bleiben oder aufgeräumt werden.

## Sonstiges

- **Cache/Config-Volumes** (`docker-borg-backup_borg-cache`/`_borg-config`)
  sind `external: true` und werden nicht von Compose verwaltet — bei einem
  frischen Host müssen sie einmalig angelegt werden (siehe oben).
- **FUSE** (`borg mount`) braucht `cap_add: SYS_ADMIN` + `/dev/fuse` im
  Container (schon in `compose.yml` hinterlegt) und ein Host-Kernel mit
  geladenem `fuse`-Modul (`modprobe fuse`, meist schon aktiv).

Willst du am Repo selbst mitarbeiten (Skripte ändern, CI/Release-Pipeline)?
Siehe [DEVELOPMENT.md](DEVELOPMENT.md).
