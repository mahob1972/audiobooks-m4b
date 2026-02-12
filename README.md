# Audiobooks m4b Pipeline (macOS)

Dieses Projekt konvertiert Hörbuch-Ordner (MP3) zu .m4b mit Kapiteln, Cover und sauberen Metadaten. Es ist für macOS + Homebrew optimiert und nutzt parallele Worker.

## Ordnerstruktur
- `rohdaten/` – ein Unterordner = ein Buch (enthält MP3, optional `front.jpg`/`cover.jpg`/`folder.jpg`)
- `ausgabe/` – erzeugte `.m4b` Dateien
- `logs/` – Lauf- und Buch-Logs
- `Skript/` – Runner/Worker/Basis-Skript und Helfer

## Installation (lokal oder bei Kollegen/Freunden)
1) Homebrew installieren (falls nicht vorhanden): https://brew.sh
2) Projekt bereitstellen – zwei Wege:
   - GitHub (empfohlen):
     ```bash
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<BRANCH>/Skript/install_deps.sh)" -- --fetch --github <OWNER>/<REPO> --branch <BRANCH> --dest "$HOME/Documents/Audiobooks" --yes
     ```
   - Manuell: Projektordner kopieren und dann Skript ausführen:
     ```bash
     "$HOME/Documents/Audiobooks/Skript/install_deps.sh" --yes
     ```

Das Installationsskript prüft/ installiert: ffmpeg (mit `libfdk_aac` bevorzugt), AtomicParsley, `gsed`, `gsort` (coreutils), optional `mpg123`. Es legt die Projektordner an und kann das Projekt (Skripte) aus GitHub synchronisieren.

## Verwendung
- Start (Dashboard + Parallelisierung):
  ```bash
  "$HOME/Documents/Audiobooks/Skript/m4b_run_v2.sh" --jobs 3 --ffmpeg-threads 2
  ```
- Worker für ein einzelnes Buch:
  ```bash
  "$HOME/Documents/Audiobooks/Skript/m4b_worker_v1.sh" "$HOME/Documents/Audiobooks/rohdaten/<Buchordner>" "$HOME/Documents/Audiobooks/ausgabe" "$HOME/Documents/Audiobooks/logs" --ffmpeg-threads 2
  ```

## Features
- Parallele Verarbeitung, Dashboard mit Fortschritt
- Kapitel pro Track, Metadaten aus Tags/Fallbacks
- Cover-Erkennung (front/cover/folder) + Auto-Skalierung (max 1400px)
- Artwork als `attached_pic` und Apple-kompatibles `covr`
- Encoder-Priorität: `libfdk_aac` → `aac` → `aac_at`
- Strg+C: sauberer Abbruch inkl. Kinderprozesse
- Abschluss-Summary + Log-Rotation (max 10 Logs/Buch)

## Troubleshooting
- Kein Cover sichtbar in Quick Look: nachträglich Artwork setzen:
  ```bash
  "$HOME/Documents/Audiobooks/Skript/m4b_retag_artwork.sh"
  ```
- libfdk_aac fehlt: Installation über Tap-Switch (`install_deps.sh` führt durch).
- Sehr kurze Laufzeiten/hohe RTF-Werte auf Apple Silicon sind normal.

## Lizenz
- Privatprojekt; passe ggf. Lizenz/Repo-Infos an.

## Release-Workflow (Tags & Changelog)
- Version taggen (SemVer empfohlen):
  ```bash
  git tag -a v1.0.0 -m "v1.0.0: erste stabile Version"
  git push origin v1.0.0
  ```
- GitHub Release anlegen: gehe zu "Releases" → "Draft a new release", wähle den Tag, füge Release Notes hinzu.
- Changelog führen (optional):
  - Lege `CHANGELOG.md` an und pflege Einträge nach Keep-a-Changelog-Format (Added/Changed/Fixed).
  - Automatisieren: benutze Conventional Commits (feat/fix/chore), dann kann ein Tool (z. B. `git-cliff`) die Release Notes generieren.

## CI (Qualität)
- GitHub Actions prüfen Shellscripts:
  - ShellCheck (Stil/Best Practices)
  - shfmt (Formatierung nur checkend)
  - Bash `-n` Syntaxprüfung
  Die Konfiguration liegt unter `.github/workflows/ci.yml`.
