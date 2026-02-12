#!/usr/bin/env bash
set -euo pipefail

# Ensure UTF-8 output for any unicode symbols
export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}

# Portable bash for calling the base script
BASH_BIN="$(command -v bash || echo /bin/bash)"

# m4b_worker_v1.sh (copy-based)
# Konvertiert GENAU EIN Buchverzeichnis nach m4b, indem es das bestehende
# m4b_maker_v3_4.sh-Skript für einen temporären Input-Root nutzt.
#
# WICHTIG:
# - Wir kopieren das Buchverzeichnis vollständig nach TMP_ROOT,
#   damit das Basis-Skript seine MP3s ganz normal mit find -type f findet.

BOOK_DIR="${1:-}"
OUTPUT_ROOT="${2:-}"
LOG_ROOT="${3:-}"
shift 3 || true

if [[ -z "$BOOK_DIR" || -z "$OUTPUT_ROOT" || -z "$LOG_ROOT" ]]; then
  echo "Usage: $(basename "$0") <BOOK_DIR> <OUTPUT_ROOT> <LOG_ROOT> [extra ffmpeg/m4b Optionen...]" >&2
  exit 1
fi

if [[ ! -d "$BOOK_DIR" ]]; then
  echo "Buch-Verzeichnis existiert nicht: $BOOK_DIR" >&2
  exit 2
fi

BOOK_NAME="$(basename "$BOOK_DIR")"

# Early skip if output already exists
if [[ -f "$OUTPUT_ROOT/$BOOK_NAME.m4b" ]]; then
  echo "⏭  Bereits vorhanden: $BOOK_NAME"
  exit 0
fi

# Robust temp dir and guaranteed cleanup
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/m4b_job.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

TMP_BOOK_DIR="$TMP_ROOT/$BOOK_NAME"
mkdir -p "$TMP_BOOK_DIR"

# Kompletten Inhalt ins TMP_BOOK_DIR kopieren (inkl. Unterordner)
# Prefer rsync if available, fallback to cp -Rp
if command -v rsync >/dev/null 2>&1; then
  rsync -a "$BOOK_DIR"/ "$TMP_BOOK_DIR"/
else
  cp -Rp "$BOOK_DIR"/. "$TMP_BOOK_DIR"/
fi

# Resolve base script in Skript folder, fallback to old location
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="$SCRIPT_DIR/m4b_maker_v3_4.sh"
if [[ ! -x "$BASE_SCRIPT" ]]; then
  BASE_SCRIPT="$HOME/Skripte/m4b_maker_v3_4.sh"
fi
if [[ ! -x "$BASE_SCRIPT" ]]; then
  echo "Basis-Skript nicht gefunden oder nicht ausführbar: $BASE_SCRIPT" >&2
  rm -rf "$TMP_ROOT"
  exit 3
fi

echo "▶️  Worker startet Buch: $BOOK_NAME"
echo "    TMP_ROOT: $TMP_ROOT"

"$BASH_BIN" "$BASE_SCRIPT" \
  --input "$TMP_ROOT" \
  --output "$OUTPUT_ROOT" \
  --logs "$LOG_ROOT" \
  "$@"

STATUS=$?

# Cleanup handled by trap

if [[ $STATUS -eq 0 ]]; then
  echo "✅ Worker fertig: $BOOK_NAME"
else
  echo "❌ Worker FEHLER ($STATUS): $BOOK_NAME"
fi

exit $STATUS
