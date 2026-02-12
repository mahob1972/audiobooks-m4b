#!/usr/bin/env bash
set -euo pipefail

# m4b_retag_artwork.sh
# Fügt Cover-Art aus den Buchordnern (rohdaten/<Buch>/) in bestehende .m4b-Dateien ein,
# ohne neu zu encodieren. Nutzt AtomicParsley --artwork und überschreibt die Datei inplace.

export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")"/.. && pwd)"
INPUT_ROOT="$PROJECT_DIR/rohdaten"
OUTPUT_ROOT="$PROJECT_DIR/ausgabe"

if ! command -v AtomicParsley >/dev/null 2>&1; then
  echo "Fehlt: AtomicParsley" >&2
  exit 1
fi

echo "Retag Artwork:"
echo " Input : $INPUT_ROOT"
echo " Output: $OUTPUT_ROOT"

shopt -s nullglob nocaseglob
mapfile -t BOOK_DIRS < <(find "$INPUT_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
if [[ ${#BOOK_DIRS[@]} -eq 0 ]]; then
  echo "Keine Buch-Ordner gefunden." >&2
  exit 0
fi

retag_one() {
  local book_dir="$1"
  local book_name; book_name="$(basename "$book_dir")"
  local out_file="$OUTPUT_ROOT/$book_name.m4b"
  if [[ ! -f "$out_file" ]]; then
    echo "⚠️  Output fehlt, überspringe: $book_name"; return 0
  fi

  local cover=""
  # 1) gängige Namen
  for name in \
    front.jpg front.jpeg front.png \
    cover.jpg cover.jpeg cover.png \
    folder.jpg folder.jpeg folder.png \
    coverart.jpg coverart.jpeg coverart.png \
    album.jpg album.jpeg album.png \
    artwork.jpg artwork.jpeg artwork.png
  do
    if [[ -f "$book_dir/$name" ]]; then cover="$book_dir/$name"; break; fi
  done
  # 2) erstes Bild
  if [[ -z "$cover" ]]; then
    local imgs=( "$book_dir"/*.{jpg,jpeg,png} )
    if (( ${#imgs[@]} > 0 )); then cover="${imgs[0]}"; fi
  fi

  if [[ -z "$cover" ]]; then
    echo "⚠️  Kein Cover im Ordner: $book_name"; return 0
  fi

  echo "🎨  Füge Cover ein: $book_name ← ${cover##*/}"
  # AtomicParsley überschreibt Datei inplace
  AtomicParsley "$out_file" --artwork "$cover" --overWrite >/dev/null 2>&1 || {
    echo "❌  AtomicParsley fehlgeschlagen bei: $book_name"; return 1; }
}

status=0
for d in "${BOOK_DIRS[@]}"; do
  retag_one "$d" || status=1
done

exit $status

