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
| `compose.yml`         | Ein Service `borg-admin`, den alle Skripte via `docker compose run` benutzen. Image kommt vorgebaut von GHCR (`docker compose pull`), `build: .` ist Fallback. |
| `DEVELOPMENT.md`      | Für Mitarbeit am Repo selbst: lokale Checks, CI/Release-Pipeline.   |
| `.env` / `.env.example` | Konfiguration (Repo-Zugang, Archiv-Präfix, Uptime-Kuma-Tokens). `.env` ist pro Host eigen und wird nicht geteilt. |
| `secrets/`            | SSH-Key, `known_hosts`, Repo-Passphrase. Pro Host eigen, siehe unten. |
| `backup.sh`           | Unbeaufsichtigter Backup-Lauf, für Cron gedacht.                    |
| `admin-compact.sh`    | Retention (`prune`) + `compact`, interaktiv per SSH-Login.          |
| `admin-shell.sh`      | Interaktive Shell im Container für Restore, `borg mount`, Ad-hoc-Kommandos. |
| `disaster-recovery-info.sh` | Druckt ein Notfall-Blatt (Repo-Adresse + Passphrase + Restore-Anleitung) für den Fall, dass dieser Host mal komplett weg ist. |
| `restore/`            | Wird nach `/restore` in den Container gemountet, landet dort Extrahiertes. |
| `logs/`               | Logs aller drei Skripte, wird automatisch nach 30 Tagen bereinigt.  |

## Ersteinrichtung

1. **Repo klonen**, egal wohin — die Skripte finden ihr eigenes Verzeichnis
   selbst (`BASE_DIR` wird aus dem Skriptpfad ermittelt).

   ```bash
   git clone git@github.com:tabacha/docker-borg-backup.git
   ```

2. **`.env` anlegen:**

   ```bash
   cp .env.example .env
   ```

   Und ausfüllen:

   | Variable                  | Bedeutung                                                        |
   |----------------------------|-------------------------------------------------------------------|
   | `BACKUP_SOURCE_DIR`        | Host-Verzeichnis, das gesichert wird (`-> /source` im Container). |
   | `BORG_SSH_USER/_HOST/_PORT`| SSH-Zugang zum Repo-Server.                                       |
   | `BORG_REPO_PATH`           | Pfad des Repos auf dem Server (z.B. `./borg-backup`).             |
   | `BORG_REMOTE_PATH`         | Name des Borg-Server-Binaries auf dem Remote (Hetzner braucht z.B. `borg-1.4`). |
   | `ARCHIVE_PREFIX`           | Präfix der Archivnamen (`::<prefix>-<zeitstempel>`), auch Filter fürs Prune. |
   | `UPTIME_KUMA_*`             | Push-Monitor für Backup und Compact. Optional — leer lassen deaktiviert den Push komplett, es wird dann gar kein Request gemacht. |

3. **`secrets/` befüllen.** Diese Dateien werden NICHT geteilt/committet
   (siehe `.gitignore`), jeder Deployment-Host braucht eigene:

   - `backup_ed25519` / `.pub` — SSH-Keypaar für den unbeaufsichtigten
     Backup-Lauf (`backup.sh`). Das ist der **Backup-Key** — mehr dazu und
     warum der eingeschränkte Rechte bekommen sollte im Abschnitt
     [Sicherheit: zwei Schlüssel](#sicherheit-zwei-schlüssel-gegen-ransomware)
     weiter unten.
   - `known_hosts` — SSH-Hostkey des Repo-Servers.
   - `passphrase` — Borg-Repo-Passphrase, eine Zeile.

   ```bash
   ssh-keygen -t ed25519 -f secrets/backup_ed25519 -C "borg-backup" -N ""
   ssh-keyscan -p "$BORG_SSH_PORT" "$BORG_SSH_HOST" > secrets/known_hosts
   echo "eine-lange-zufaellige-passphrase" > secrets/passphrase
   chmod 600 secrets/backup_ed25519 secrets/passphrase
   ```

   Den Public Key (`secrets/backup_ed25519.pub`) beim Repo-Provider hinterlegen.

4. **Externe Docker-Volumes anlegen** (Cache/Config bleiben so über
   Image-Updates hinweg erhalten):

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

6. **Borg-Repo einmalig initialisieren** (nur beim allerersten Mal, für ein
   neues/leeres Repo). Das ist eine Admin-Operation, braucht also den
   Admin-Key per Agent-Forwarding — am einfachsten direkt in `admin-shell.sh`
   (siehe unten, `ssh -tA user@host /pfad/zum/repo/admin-shell.sh`) und dort:

   ```bash
   borg init --encryption=repokey-blake2
   ```

   Alternativ auch von außen möglich, dann aber selbst für ein gesetztes
   `SSH_AUTH_SOCK` mit Zugriff auf den Repo-Server sorgen:

   ```bash
   docker compose run --rm borg-admin init --encryption=repokey-blake2
   ```

## Laufender Betrieb

### Automatisches Backup — `backup.sh`

Für Cron gedacht, z.B. täglich nachts:

```
0 3 * * * /pfad/zum/repo/backup.sh
```

- Baut sich selbst einen SSH-Agent auf, lädt `secrets/backup_ed25519`, entlädt
  ihn am Ende garantiert wieder (auch bei Fehlern).
- Läuft komplett still (`exec >logfile 2>&1`), meldet Erfolg/Fehler nur per
  Uptime-Kuma-Push und Exit-Code.
- Verhindert Überlappung über einen `flock` auf
  `/run/lock/docker-borg-backup.lock` — läuft schon ein Backup oder
  `admin-compact.sh`, beendet sich ein zweiter Lauf still mit Exit 0.
- Logs unter `logs/backup-<zeitstempel>.log`, 30 Tage Aufbewahrung.

### Wartung — `admin-compact.sh`

Retention (`prune`) + `compact`, macht das Repo nicht kleiner, wenn man's nicht
regelmäßig laufen lässt. Braucht einen per SSH weitergereichten Agent:

```bash
ssh -A user@host /pfad/zum/repo/admin-compact.sh
```

- Bricht ab, wenn `SSH_AUTH_SOCK` fehlt (`ssh -A` vergessen) oder gerade ein
  Backup/Compact läuft (gleicher Lock wie `backup.sh`).
- Zeigt Archive vorher/nachher, wendet die Retention aus `admin-compact.sh` an
  (`--keep-within 2d --keep-daily 7 --keep-weekly 3 --keep-monthly 12
  --keep-yearly 2` — bei Bedarf im Skript anpassen), kompaktiert danach.
- Ausgabe geht aufs Terminal UND nach `logs/admin-compact-<zeitstempel>.log`.
- Uptime-Kuma-Push wie beim Backup.

### Interaktive Shell — `admin-shell.sh`

Für alles, was man selten braucht: einzelne Dateien wiederherstellen, ein
Archiv löschen, nach alten Dateien suchen. Braucht ein echtes TTY:

```bash
ssh -tA user@host /pfad/zum/repo/admin-shell.sh
```

- Landet in einer Bash direkt im Borg-Container, `BORG_REPO` /
  `BORG_PASSCOMMAND` / `BORG_RSH` sind schon gesetzt — `borg` also ohne
  Repo-Pfad aufrufen.
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
- Hält denselben Lock wie Backup/Compact, solange die Shell offen ist.
- Komplette Sitzung (Befehle + Ausgabe) wird nach
  `logs/admin-shell-<zeitstempel>.log` mitgeschnitten.
- Container wird beim Verlassen (`exit`) automatisch entfernt (`--rm`).

## Sicherheit: zwei Schlüssel gegen Ransomware

`backup.sh` benutzt aktuell genau einen SSH-Key (`secrets/backup_ed25519`),
der unverschlüsselt als Datei auf dem Host liegt, der gesichert wird. Das ist
der klassische Single-Point-of-Failure bei Backups: Wird der Host kompromittiert,
hat der Angreifer auch den Schlüssel zum Backup-Repo — und kann die Backups
löschen, bevor er die eigentlichen Daten verschlüsselt.

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
| **Backup-Key** (`secrets/backup_ed25519`) | Als Datei auf dem gesicherten Host (unvermeidbar für unbeaufsichtigten Cron-Betrieb) | Nur **append-only**: neue Archive schreiben, nichts endgültig löschen | `backup.sh` |
| **Admin-Key** | NUR im eigenen SSH-Agent des Admins (per `ssh -A`/`ssh -tA` weitergereicht) — landet nie als Datei auf dem gesicherten Host | Voll: `prune`, `compact`, `delete` | `admin-compact.sh`, `admin-shell.sh` |

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
  Repo-Server, vor dem Public Key des Backup-Keys:
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
oben, …), sind `.env` und `secrets/` genauso weg. Übrig bleibt bestenfalls
ein privater SSH-Key, den jemand getrennt aufbewahrt hat (Passwort-Tresor,
USB-Stick im Safe, …) — aber ein Key allein bringt nichts ohne die
Repo-Adresse und die Passphrase.

`disaster-recovery-info.sh` liest `.env` + `secrets/passphrase` +
`secrets/known_hosts` und druckt daraus ein einziges, in sich
geschlossenes Blatt: fertige `BORG_REPO`/`BORG_RSH`/`BORG_PASSPHRASE`-Werte
zum Copy-Paste, den SSH-Hostkey zum Pinnen, und zwei komplette
Restore-Anleitungen (mit reinem `pip install borgbackup` ganz ohne Docker,
und mit diesem Repo). Es spricht dabei nicht mit Docker oder dem Repo-Server
und schreibt bewusst nichts nach `logs/` — die Ausgabe enthält die
Passphrase im Klartext.

```bash
./disaster-recovery-info.sh > /tmp/recovery-sheet.txt   # dann SOFORT weg von hier:
# ausdrucken + Safe, oder als Secure Note in den Passwort-Tresor, dann
# /tmp/recovery-sheet.txt wieder löschen.
```

Bei jeder Änderung an `.env`/`secrets/passphrase`/`secrets/known_hosts` neu
laufen lassen und das alte Blatt ersetzen.

## Sonstiges

- **Cache/Config-Volumes** (`docker-borg-backup_borg-cache`/`_borg-config`)
  sind `external: true` und werden nicht von Compose verwaltet — bei einem
  frischen Host müssen sie einmalig angelegt werden (siehe oben).
- **FUSE** (`borg mount`) braucht `cap_add: SYS_ADMIN` + `/dev/fuse` im
  Container (schon in `compose.yml` hinterlegt) und ein Host-Kernel mit
  geladenem `fuse`-Modul (`modprobe fuse`, meist schon aktiv).

Willst du am Repo selbst mitarbeiten (Skripte ändern, CI/Release-Pipeline)?
Siehe [DEVELOPMENT.md](DEVELOPMENT.md).
