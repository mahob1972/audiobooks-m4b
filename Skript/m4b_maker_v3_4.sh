#!/usr/bin/env bash
set -euo pipefail

# m4b_maker_v3_4.sh — macOS 26.1 (Apple Silicon)
# - Default-Ordner (immer gegeben):
#     INPUT_ROOT  = ~/Hörbuchprojekt/Eingabe_Buch
#     OUTPUT_ROOT = ~/Hörbuchprojekt/Ausgabe
#     LOG_ROOT    = ~/Hörbuchprojekt/Logs
#   (per CLI weiterhin überschreibbar)
# - JEDER Unterordner von INPUT_ROOT ist EIN Buch und wird NACHEINANDER verarbeitet.
# - Dateiname = exakt der Buchordner-Name.
# - Immer MP3 -> WAV (ruhig & tolerant), dann WAV concat -> Apple AAC (aac_at).
# - Fortschrittszeile (exakt): "⏱ Laufzeit HH:MM:SS | RTF ddd,dd | encodiert HH:MM:SS / HH:MM:SS"
# - Cover & Metadaten aus MP3 nutzen, wenn vorhanden:
#     * Cover: APIC/attached_pic aus dem ersten MP3 mit eingebettetem Bild extrahieren
#     * Tags (Album/Artist/Year): aus erstem MP3 ziehen, falls CLI nicht gesetzt
# - Kapitel pro Track, AtomicParsley Audiobook-Tag.
#
# Abhängigkeiten: ffmpeg, ffprobe, AtomicParsley, gnu-sed (gsed), coreutils (gsort)
# Optional: mpg123 (schneller/toleranter für MP3->WAV)

# ------------------------- Defaults ------------------------------------------
INPUT_ROOT="${HOME}/Hörbuchprojekt/Eingabe_Buch"
OUTPUT_ROOT="${HOME}/Hörbuchprojekt/Ausgabe"
LOG_ROOT="${HOME}/Hörbuchprojekt/Logs"

TITLE=""
AUTHOR=""
ALBUM=""
YEAR=""
BITRATE="128k"
FFMPEG_THREADS=2

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--input DIR] [--output DIR] [--logs DIR]
       [--title T] [--author A] [--album ALB] [--year YYYY] [--bitrate 128k]
       [--ffmpeg-threads N]

Ohne Parameter werden die Defaults genutzt:
  --input          = $INPUT_ROOT
  --output         = $OUTPUT_ROOT
  --logs           = $LOG_ROOT
  --ffmpeg-threads = $FFMPEG_THREADS
USAGE
}

# ------------------------- CLI ----------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)   INPUT_ROOT=${2:-}; shift 2;;
    --output)  OUTPUT_ROOT=${2:-}; shift 2;;
    --logs)    LOG_ROOT=${2:-}; shift 2;;
    --title)   TITLE=${2:-}; shift 2;;
    --author)  AUTHOR=${2:-}; shift 2;;
    --album)   ALBUM=${2:-}; shift 2;;
    --year)    YEAR=${2:-}; shift 2;;
    --bitrate) BITRATE=${2:-}; shift 2;;
    --ffmpeg-threads) FFMPEG_THREADS=${2:-2}; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 1;;
  esac
done

requires() { command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }; }
requires ffmpeg
requires ffprobe
requires AtomicParsley
requires gsed
requires gsort

# Encoder-Verfügbarkeit erfassen und Fallback-Reihenfolge bestimmen
# Codec-Priorität: libfdk_aac → aac → aac_at (Apple-Encoder zuletzt)
AVAIL=()
ffenc_list=$(ffmpeg -hide_banner -v error -encoders || true)
[[ "$ffenc_list" =~ \ libfdk_aac\  ]] && AVAIL+=("libfdk_aac")
[[ "$ffenc_list" =~ \ aac\  ]] && AVAIL+=("aac")
[[ "$ffenc_list" =~ \ aac_at\  ]] && AVAIL+=("aac_at")

CODEC_ORDER=()
[[ "$ffenc_list" =~ \ libfdk_aac\  ]] && CODEC_ORDER+=("libfdk_aac")
[[ "$ffenc_list" =~ \ aac\  ]] && CODEC_ORDER+=("aac")
[[ "$ffenc_list" =~ \ aac_at\  ]] && CODEC_ORDER+=("aac_at")

if [[ ${#CODEC_ORDER[@]} -eq 0 ]]; then
  echo "Kein geeigneter AAC-Encoder gefunden (aac_at/libfdk_aac/aac)." >&2
  exit 1
fi

echo "AAC-Encoder verfügbar: ${AVAIL[*]}"
echo "Codec-Priorität     : ${CODEC_ORDER[*]}"
if [[ ! "$ffenc_list" =~ \ libfdk_aac\  ]]; then
  echo "Hinweis: Für beste Qualität libfdk_aac installieren:"
  echo "  brew tap homebrew-ffmpeg/ffmpeg"
  echo "  brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac"
fi

# Ordner anlegen
mkdir -p "$OUTPUT_ROOT" "$LOG_ROOT" "$INPUT_ROOT"

echo "== m4b_maker_v3_4.sh gestartet: $(date) =="
echo "Input-Root : $INPUT_ROOT"
echo "Output-Root: $OUTPUT_ROOT"
echo "Logs       : $LOG_ROOT"

# ------------------------- Bücher auflisten ----------------------------------
# Ein Buch = ein direkter Unterordner von INPUT_ROOT
mapfile -t BOOK_DIRS < <(find "$INPUT_ROOT" -mindepth 1 -maxdepth 1 -type d | gsort -V)
if [[ ${#BOOK_DIRS[@]} -eq 0 ]]; then
  echo "Keine Buch-Ordner in $INPUT_ROOT gefunden." >&2
  exit 1
fi

format_time() {
  local S="$1"
  printf "%02d:%02d:%02d" $((S/3600)) $(((S%3600)/60)) $((S%60))
}
fmt_rtf_comma() {
  local a="$1"; local e="$2"
  if [[ "$e" -le 0 ]]; then printf "0,00"; return; fi
  local val; val=$(awk -v x="$a" -v y="$e" 'BEGIN{ printf "%.2f", (y>0? x/y : 0) }')
  printf "%s" "$val" | gsed 's/\./,/' 2>/dev/null || printf "%s" "$val" | sed 's/\./,/'
}

# Hilfsfunktionen zum Auslesen von Tags aus einem MP3 (per ffprobe)
get_tag_from_mp3() {
  # $1: Datei, $2: tagname (title|artist|album|date|year)
  local f="$1"; local tag="$2"; local val=""
  case "$tag" in
    year)
      # Manche Dateien haben nur 'date'; wir extrahieren die ersten 4 Ziffern als Jahr
      local d; d="$(ffprobe -v error -show_entries format_tags=date -of default=nw=1:nk=1 "$f" || true)"
      if [[ -n "${d:-}" ]]; then
        val="$(printf "%s" "$d" | sed -E 's/[^0-9]//g' | cut -c1-4)"
      else
        # direkter year-Tag
        val="$(ffprobe -v error -show_entries format_tags=year -of default=nw=1:nk=1 "$f" || true)"
        val="$(printf "%s" "${val:-}" | sed -E 's/[^0-9]//g' | cut -c1-4)"
      fi
      ;;
    *)
      val="$(ffprobe -v error -show_entries format_tags="$tag" -of default=nw=1:nk=1 "$f" || true)"
      ;;
  esac
  # Nur die erste Zeile, Trim
  val="$(printf "%s" "${val:-}" | head -n1 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  printf "%s" "$val"
}

has_attached_pic() {
  # $1: Datei; return 0 wenn attached_pic vorhanden
  local f="$1"
  # Prüfen, ob ein Videostream mit attached_pic existiert
  if ffprobe -v error -select_streams v:0 -show_entries stream=disposition -of default=nw=1:nk=1 "$f" 2>/dev/null | grep -qi "attached_pic=1"; then
    return 0
  else
    return 1
  fi
}

extract_cover_from_mp3() {
  # $1: Datei, $2: Zielbildpfad (jpg/png je nach Quelle)
  local f="$1"; local out="$2"
  # Wir kopieren den Anhang unverändert heraus
  ffmpeg -hide_banner -loglevel error -i "$f" -map 0:v -c copy "$out"
}

process_book() {
  local BOOK_DIR="$1"
  local BOOK_NAME; BOOK_NAME="$(basename "$BOOK_DIR")"
  local TIMESTAMP; TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  local LOG_FILE="$LOG_ROOT/${BOOK_NAME}_${TIMESTAMP}.log"
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo "📚 Starte Buch: $BOOK_NAME"
  echo "Log: $LOG_FILE"
  echo "────────────────────────────────────────────────────────"
  # Log-Datei: subshell für den gesamten Buchlauf
  (
    set -euo pipefail
    echo "== Buchlauf gestartet: $(date) =="
    # Tracks sammeln (rekursiv)
    mapfile -t TRACKS < <(find "$BOOK_DIR" -type f -iname "*.mp3" | gsort -V)
    if [[ ${#TRACKS[@]} -eq 0 ]]; then
      echo "WARN: Keine MP3s in $BOOK_DIR – überspringe."
      exit 0
    fi
    echo "Tracks: ${#TRACKS[@]}"

    # Workdir
    WORKDIR=$(mktemp -d)
    cleanup() { rm -rf "$WORKDIR"; }
    trap cleanup EXIT

    # --- Cover & Metadaten aus MP3 ermitteln (falls kein Ordner-Cover vorhanden) ---
    COVER=""
    # 1) Häufige Dateinamen (case-insensitive) direkt im Buchordner
    shopt -s nullglob nocaseglob
    for name in \
      cover.jpg cover.jpeg cover.png \
      folder.jpg folder.jpeg folder.png \
      front.jpg front.jpeg front.png \
      coverart.jpg coverart.jpeg coverart.png \
      album.jpg album.jpeg album.png \
      artwork.jpg artwork.jpeg artwork.png
    do
      if [[ -f "$BOOK_DIR/$name" ]]; then COVER="$BOOK_DIR/$name"; break; fi
    done
    # 2) Fallback: erstes Bild im Ordner (jpg/jpeg/png)
    if [[ -z "$COVER" ]]; then
      imgs=( "$BOOK_DIR"/*.{jpg,jpeg,png} )
      if (( ${#imgs[@]} > 0 )); then COVER="${imgs[0]}"; fi
    fi
    shopt -u nocaseglob

    FIRST_WITH_PIC=""
    if [[ -z "$COVER" ]]; then
      for mp3 in "${TRACKS[@]}"; do
        if has_attached_pic "$mp3"; then
          FIRST_WITH_PIC="$mp3"; break
        fi
      done
      if [[ -n "$FIRST_WITH_PIC" ]]; then
        # Ausgabeformat: wir versuchen .jpg; ffmpeg lässt Originalformat
        COVER="$WORKDIR/cover_from_id3.jpg"
        extract_cover_from_mp3 "$FIRST_WITH_PIC" "$COVER" || COVER=""
      fi
    fi

    if [[ -n "$COVER" ]]; then
      echo "Cover: ja (${COVER##*/})"
      # Auto-Skalierung: max 1400x1400, Seitenverhältnis beibehalten, Ausgabe JPG
      SCALED_COVER="$WORKDIR/cover_scaled.jpg"
      if ffmpeg -hide_banner -loglevel error -y -i "$COVER" \
        -vf "scale='min(1400,iw)':'min(1400,ih)':force_original_aspect_ratio=decrease" \
        -frames:v 1 -q:v 2 "$SCALED_COVER"; then
        COVER="$SCALED_COVER"
        echo "Cover skaliert (max 1400px): ${COVER##*/}"
      else
        echo "WARN: Cover-Skalierung fehlgeschlagen – nutze Original."
      fi
    else
      echo "Cover: nein"
    fi

    # Metadaten-Fallback-Logik (CLI > MP3-Tags > Ordnername)
    local MP3_FOR_TAGS="${TRACKS[0]}"
    local TAG_ALBUM TAG_ARTIST TAG_YEAR
    TAG_ALBUM="$(get_tag_from_mp3 "$MP3_FOR_TAGS" album)"
    TAG_ARTIST="$(get_tag_from_mp3 "$MP3_FOR_TAGS" artist)"
    TAG_YEAR="$(get_tag_from_mp3 "$MP3_FOR_TAGS" year)"

    local FINAL_TITLE FINAL_ARTIST FINAL_ALBUM FINAL_YEAR
    FINAL_TITLE="${TITLE:-}";   [[ -z "$FINAL_TITLE"  ]] && FINAL_TITLE="${TAG_ALBUM:-}"
    FINAL_ARTIST="${AUTHOR:-}"; [[ -z "$FINAL_ARTIST" ]] && FINAL_ARTIST="${TAG_ARTIST:-}"
    FINAL_ALBUM="${ALBUM:-}";   [[ -z "$FINAL_ALBUM"  ]] && FINAL_ALBUM="${TAG_ALBUM:-}"
    FINAL_YEAR="${YEAR:-}";     [[ -z "$FINAL_YEAR"   ]] && FINAL_YEAR="${TAG_YEAR:-}"

    [[ -z "$FINAL_TITLE" ]] && FINAL_TITLE="$BOOK_NAME"
    [[ -z "$FINAL_ALBUM" ]] && FINAL_ALBUM="$BOOK_NAME"

    echo "Metadaten: title='${FINAL_TITLE}' artist='${FINAL_ARTIST}' album='${FINAL_ALBUM}' year='${FINAL_YEAR}'"

    # MP3 -> WAV (ruhig & tolerant)
    SANITIZE_DIR="$WORKDIR/wav"
    mkdir -p "$SANITIZE_DIR"
    WAVS=()
    idx=1
    if command -v mpg123 >/dev/null 2>&1; then HAVE_MPG123=1; else HAVE_MPG123=0; fi
    echo "Sanitizing (MP3→WAV)…"
    for f in "${TRACKS[@]}"; do
      w="$SANITIZE_DIR/$(printf "%05d" "$idx").wav"
      if [[ $HAVE_MPG123 -eq 1 ]]; then
        mpg123 --quiet -w "$w" "$f" || {
          echo "WARN: mpg123 scheiterte an $f – fallback ffmpeg."
          ffmpeg -hide_banner -loglevel error -fflags +discardcorrupt \
            -i "$f" -vn -sn -dn -ar 44100 -ac 2 -c:a pcm_s16le "$w"
        }
      else
        ffmpeg -hide_banner -loglevel error -fflags +discardcorrupt \
          -i "$f" -vn -sn -dn -ar 44100 -ac 2 -c:a pcm_s16le "$w"
      fi
      WAVS+=("$w"); idx=$((idx+1))
    done

    # Concat-Liste & Kapitel
    LIST_FILE="$WORKDIR/concat_list.txt"
    META_FILE="$WORKDIR/chapters.ffmeta"
    : > "$LIST_FILE"; : > "$META_FILE"
    echo ";FFMETADATA1" >> "$META_FILE"
    echo "; TIMEBASE 1/1000 (Millisekunden)" >> "$META_FILE"
    TIMEBASE=1000; CUM_MS=0; IDX=1

    get_title_for_index() {
      local i="$1"; local base
      base=$(basename "${TRACKS[$((i-1))]}")
      printf "%s" "${base%.*}"
    }

    for i in "${!WAVS[@]}"; do
      f="${WAVS[$i]}"
      escaped_path=$(printf "%s" "$f" | gsed "s/'/'\\\\''/g")
      printf "file '%s'\n" "$escaped_path" >> "$LIST_FILE"
      DUR_S=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f"); [[ -z "$DUR_S" ]] && DUR_S="0"
      DUR_MS=$(python3 - <<PY
import math
print(int(round(float("${DUR_S}")*1000)))
PY
)
      title=$(get_title_for_index $((i+1)))
      START=$CUM_MS; END=$((CUM_MS + DUR_MS - 1))
      cat >> "$META_FILE" <<CHAP
[CHAPTER]
TIMEBASE=1/$TIMEBASE
START=$START
END=$END
TITLE=$IDX. $title
CHAP
      CUM_MS=$((CUM_MS + DUR_MS)); IDX=$((IDX + 1))
    done
    TOTAL_MS=$CUM_MS
    TOTAL_SEC=$((TOTAL_MS/1000))
    echo "Gesamtdauer: $(format_time "$TOTAL_SEC")"

    # Encoding + Fortschritt
    OUT_FILE="$OUTPUT_ROOT/${BOOK_NAME}.m4b"
    TMP_FILE="$WORKDIR/out_tmp.m4b"
    do_encode() {
      local codec="$1"
      local fifo reader ff_status
      fifo="$WORKDIR/ffprogress_${codec}.fifo"; mkfifo "$fifo"
      START_TS=$(date +%s); TOTAL_SEC=$((TOTAL_MS/1000))
      (
        encoded_sec=0
        printf "\r⏱ Laufzeit %s | RTF %s | encodiert %s / %s" \
          "$(format_time 0)" "$(fmt_rtf_comma 0 1)" "$(format_time 0)" "$(format_time "$TOTAL_SEC")"
        while IFS= read -r line; do
          case "$line" in
            out_time_ms=*) val="${line#out_time_ms=}"; [[ "$val" =~ ^[0-9]+$ ]] && encoded_sec=$(( val/1000000 ));;
          esac
          now=$(date +%s); elapsed=$((now-START_TS))
          rtf="$(fmt_rtf_comma "$encoded_sec" "$elapsed")"
          printf "\r⏱ Laufzeit %s | RTF %s | encodiert %s / %s" \
            "$(format_time "$elapsed")" \
            "$rtf" \
            "$(format_time "$encoded_sec")" \
            "$(format_time "$TOTAL_SEC")"
        done < "$fifo"
      ) &
      reader=$!

      FFMPEG_CMD=(
        ffmpeg -hide_banner -loglevel error -y
        -progress "$fifo" -nostats
        -fflags +genpts
        -f concat -safe 0 -i "$LIST_FILE"
        -i "$META_FILE"
      )

      # Audio-Mapping & Codec
      FFMPEG_CMD+=( -map 0:a -vn -c:a "$codec" -b:a "$BITRATE" -threads "$FFMPEG_THREADS" -avoid_negative_ts make_zero -movflags use_metadata_tags )

      
      # Kapitel aus ffmetadata (Input 1)
      FFMPEG_CMD+=( -map_chapters 1 )

      # Ausgabedatei
      FFMPEG_CMD+=( "$TMP_FILE" )

      echo "Starte Encoding mit Codec '$codec' …"
      set +e; "${FFMPEG_CMD[@]}"; ff_status=$?; set -e
      kill "$reader" >/dev/null 2>&1 || true; echo ""
      return "$ff_status"
    }

    # Versuche nacheinander die verfügbaren Codecs
    ENCODE_OK=0
    for codec in "${CODEC_ORDER[@]}"; do
      if do_encode "$codec"; then ENCODE_OK=1; echo "Codec '$codec' erfolgreich."; break; else echo "Codec '$codec' fehlgeschlagen – versuche Fallback…"; fi
    done
    if [[ $ENCODE_OK -ne 1 ]]; then
      echo "FFmpeg-Fehler: alle Codecs fehlgeschlagen."; exit 1
    fi

    echo "Audiobook-Tagging …"
    AP_ARGS=( "--stik" "Audiobook" )
    # Artwork via AtomicParsley (erzeugt 'covr' Atom, kompatibel mit Apple-Apps)
    if [[ -n "$COVER" && -f "$COVER" ]]; then
      AP_ARGS+=( "--artwork" "$COVER" )
    fi
    [[ -n "$FINAL_TITLE"  ]] && AP_ARGS+=( "--title"  "$FINAL_TITLE" )
    [[ -n "$FINAL_ARTIST" ]] && AP_ARGS+=( "--artist" "$FINAL_ARTIST" )
    [[ -n "$FINAL_ALBUM"  ]] && AP_ARGS+=( "--album"  "$FINAL_ALBUM" )
    [[ -n "$FINAL_YEAR"   ]] && AP_ARGS+=( "--year"   "$FINAL_YEAR" )
    AtomicParsley "$TMP_FILE" "${AP_ARGS[@]}" --overWrite

    mv -f "$TMP_FILE" "$OUT_FILE" 2>/dev/null || true
    if [[ -f "$OUT_FILE" ]]; then
      echo "✅ Fertig: $OUT_FILE"
    else
      if [[ -f "$TMP_FILE" ]]; then
        mv "$TMP_FILE" "$OUT_FILE"
        echo "✅ Fertig (Fallback): $OUT_FILE"
      else
        echo "❌ Fehler: Ausgabedatei nicht gefunden."; exit 1
      fi
    fi
    echo "== Buchlauf fertig: $(date) =="
  ) | tee -a "$LOG_FILE"

  # Log-Rotation pro Buch (max 10 Logs behalten)
  shopt -s nullglob
  mapfile -t _book_logs < <(ls -1t "$LOG_ROOT/$BOOK_NAME"_*.log 2>/dev/null || true)
  shopt -u nullglob
  if (( ${#_book_logs[@]} > 10 )); then
    to_delete=( "${_book_logs[@]:10}" )
    rm -f -- "${to_delete[@]}" 2>/dev/null || true
  fi
}

# ------------------------- Sequenziell verarbeiten ----------------------------
TOTAL_BOOKS=${#BOOK_DIRS[@]}
idx=1
for book in "${BOOK_DIRS[@]}"; do
  echo ""
  echo "==> ($idx/$TOTAL_BOOKS) Verarbeite: $(basename "$book")"
  process_book "$book"
  idx=$((idx+1))
done

echo ""
echo "🎉 Alle Bücher fertig."
