#!/usr/bin/env bash
set -euo pipefail

# Ensure UTF-8 for dashboard rendering
export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}
# Prevent non-interactive shells from sourcing user env files that may print noise
unset BASH_ENV ENV || true

# Portable bash resolver (fallback to /bin/bash)
BASH_BIN="$(command -v bash || echo /bin/bash)"

# Farben für das Dashboard
CLR_RESET=$'\033[0m'
CLR_DIM=$'\033[2m'
CLR_GREEN=$'\033[32m'
CLR_YELLOW=$'\033[33m'
CLR_CYAN=$'\033[36m'

# Project-local roots (Audiobooks folder)
# Resolve script dir and project root (parent of Skript)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
INPUT_ROOT="$PROJECT_DIR/rohdaten"
OUTPUT_ROOT="$PROJECT_DIR/ausgabe"
LOG_ROOT="$PROJECT_DIR/logs"

MAX_JOBS=3
FFMPEG_THREADS=2

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--jobs N] [--ffmpeg-threads N]
       [weitere m4b-Optionen werden durchgereicht]

Defaults:
  Input  (fix)     = $INPUT_ROOT
  Output (fix)     = $OUTPUT_ROOT
  Logs   (fix)     = $LOG_ROOT
  --jobs           = $MAX_JOBS
  --ffmpeg-threads = $FFMPEG_THREADS
USAGE
}

EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)           echo "Hinweis: --input wird ignoriert (Projektpfade sind fest)." >&2; shift 2;;
    --output)          echo "Hinweis: --output wird ignoriert (Projektpfade sind fest)." >&2; shift 2;;
    --logs)            echo "Hinweis: --logs wird ignoriert (Projektpfade sind fest)." >&2; shift 2;;
    --jobs)            MAX_JOBS=${2:-3}; shift 2;;
    --ffmpeg-threads)  FFMPEG_THREADS=${2:-2}; shift 2;;
    -h|--help)         usage; exit 0;;
    *)                 EXTRA_ARGS+=("$1"); shift;;
  esac
done

# Ensure project directories exist
mkdir -p "$INPUT_ROOT" "$OUTPUT_ROOT" "$LOG_ROOT"

# Resolve worker in Skript folder, fallback to old location
WORKER="$SCRIPT_DIR/m4b_worker_v1.sh"
if [[ ! -x "$WORKER" ]]; then
  WORKER="$HOME/Skripte/m4b_parallel/m4b_worker_v1.sh"
fi
if [[ ! -x "$WORKER" ]]; then
  echo "Worker-Skript nicht gefunden oder nicht ausführbar: $WORKER" >&2
  exit 2
fi

# Buchverzeichnisse einsammeln
BOOK_DIRS=()
while IFS= read -r -d '' d; do
  BOOK_DIRS+=("$d")
done < <(find "$INPUT_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

TOTAL=${#BOOK_DIRS[@]}
if [[ $TOTAL -eq 0 ]]; then
  echo "Keine Buch-Ordner in $INPUT_ROOT gefunden."
  exit 0
fi

BOOK_NAMES=()
for b in "${BOOK_DIRS[@]}"; do
  BOOK_NAMES+=("$(basename "$b")")
done

RUNNER_LOG="$LOG_ROOT/m4b_run_$(date +%Y%m%d_%H%M%S).log"

printf '%s\0' "${BOOK_DIRS[@]}" \
  | xargs -0 -n1 -P "$MAX_JOBS" -I{} \
    "$BASH_BIN" -c 'exec "$0" "$1" "$2" "$3" --ffmpeg-threads "$4" "${@:5}"' \
      "$WORKER" {} "$OUTPUT_ROOT" "$LOG_ROOT" "$FFMPEG_THREADS" "${EXTRA_ARGS[@]}" \
  >"$RUNNER_LOG" 2>&1 &
ENGINE_PID=$!

# ---- Ctrl+C/TERM an Kinder weitergeben ----
kill_tree() {
  local pid="$1"
  [[ -z "${pid:-}" ]] && return 0
  if ! kill -0 "$pid" >/dev/null 2>&1; then return 0; fi
  # Zuerst direkte Kinder terminieren
  pkill -TERM -P "$pid" >/dev/null 2>&1 || true
  # Rekursiv über alle Nachfahren
  local kids
  kids=$(pgrep -P "$pid" 2>/dev/null || true)
  for k in $kids; do
    kill_tree "$k"
  done
  # Zuletzt den übergebenen Prozess
  kill -TERM "$pid" >/dev/null 2>&1 || true
}

trap 'echo; echo "⚠️ Abbruch – beende Jobs…"; kill_tree "$ENGINE_PID"; kill -TERM "$ENGINE_PID" >/dev/null 2>&1 || true; wait "$ENGINE_PID" 2>/dev/null || true; exit 130' INT
trap 'kill_tree "$ENGINE_PID"; kill -TERM "$ENGINE_PID" >/dev/null 2>&1 || true' TERM

shorten() {
  local maxlen="$1"; shift
  local s="$*"
  local len=${#s}
  if (( len <= maxlen )); then
    printf "%s" "$s"
  else
    printf "%s…" "${s:0:maxlen-1}"
  fi
}

print_sep() {
  local width=$1
  printf '%*s\n' "$width" '' | tr ' ' '─'
}

print_dashboard() {
  printf "\033[H\033[J"

  # Tabellen-Spaltenbreiten
  local col_hash=3
  local col_book=100
  local col_status=20
  local col_prog=250

  # sichtbare Gesamtbreite am Terminal
  local cols
  cols=$(tput cols 2>/dev/null || echo 120)

  # theoretische Tabellenbreite
  local table_width=$((col_hash + 2 + col_book + 2 + col_status + 2 + col_prog))

  # Separator-Breite = min(Terminalbreite, Tabellenbreite)
  local sep_width=$cols
  if (( table_width < cols )); then
    sep_width=$table_width
  fi

  print_sep "$sep_width"
  echo "m4b Dashboard — $(date +%H:%M:%S)"
  echo "Input : $(shorten 100 "$INPUT_ROOT")"
  echo "Jobs  : $MAX_JOBS  | ffmpeg-threads: $FFMPEG_THREADS"
  print_sep "$sep_width"
  printf "%-3s  %-100s  %-20s  %-250s\n" "#" "Buch" "Status" "Fortschritt"
  print_sep "$sep_width"

  local max_progress=250

  local idx=0
  for name in "${BOOK_NAMES[@]}"; do
    idx=$((idx+1))
    local status="wartet"
    local progress="–"

    shopt -s nullglob
    local logs=( "$LOG_ROOT/$name"_*.log )
    shopt -u nullglob

    if (( ${#logs[@]} > 0 )); then
      local log="${logs[-1]}"

      if grep -q "WARN: Keine MP3s" "$log" 2>/dev/null; then
        status="übersprungen"
      else
        status="läuft"
      fi

      local line
      line="$(grep '⏱ Laufzeit' "$log" 2>/dev/null | tail -n 1 || true)"
      if [[ -n "$line" ]]; then
        progress="$line"
        progress="${progress##*$'\r'}"
      elif [[ "$status" == "läuft" ]]; then
        progress="Initialisierung…"
      fi
    fi

    local outfile="$OUTPUT_ROOT/$name.m4b"
    if [[ -f "$outfile" ]]; then
      status="fertig"
    fi

    local status_colored="$status"
    case "$status" in
      fertig)       status_colored="${CLR_GREEN}${status}${CLR_RESET}" ;;
      läuft)        status_colored="${CLR_YELLOW}${status}${CLR_RESET}" ;;
      wartet)       status_colored="${CLR_DIM}${status}${CLR_RESET}" ;;
      übersprungen) status_colored="${CLR_CYAN}${status}${CLR_RESET}" ;;
      *)            status_colored="$status" ;;
    esac

    if [[ "$progress" == *"⏱"* ]]; then
      progress="${progress#*⏱ }"
    fi
    progress="$(shorten "$max_progress" "$progress")"

    printf "%-3s  %-100s  %-20s  %-250s\n" \
      "$idx" \
      "$(shorten 100 "$name")" \
      "$status_colored" \
      "$progress"
  done

  print_sep "$sep_width"
  echo "Engine-Log: $RUNNER_LOG"
  echo "Strg+C: beendet Engine und Kinderprozesse (sauberer Abbruch)."
}

while kill -0 "$ENGINE_PID" >/dev/null 2>&1; do
  print_dashboard
  sleep 1
done

print_dashboard
echo ""
echo "🎉 Alle parallelen Jobs beendet."

# -------------------- Abschluss-Summary --------------------
print_summary() {
  local cols sep_width
  cols=$(tput cols 2>/dev/null || echo 120)
  sep_width=$cols
  print_sep "$sep_width"
  echo "Abschluss-Summary"
  print_sep "$sep_width"

  local finished=() skipped=() failed=()
  local name log outfile

  for name in "${BOOK_NAMES[@]}"; do
    outfile="$OUTPUT_ROOT/$name.m4b"

    # Letztes Buch-Log ermitteln
    shopt -s nullglob
    local logs=( "$LOG_ROOT/$name"_*.log )
    shopt -u nullglob
    log=""
    if (( ${#logs[@]} > 0 )); then
      log="${logs[-1]}"
    fi

    # Status ableiten: failed > finished > skipped > unknown
    if grep -Fq "❌ Worker FEHLER" "$RUNNER_LOG" 2>/dev/null | grep -Fq "$name" 2>/dev/null; then
      failed+=("$name")
    elif [[ -f "$outfile" ]]; then
      finished+=("$name")
    elif [[ -n "$log" ]] && grep -q "WARN: Keine MP3s" "$log" 2>/dev/null; then
      skipped+=("$name")
    else
      # Falls unklar und keine Ausgabedatei vorhanden, als failed markieren
      failed+=("$name")
    fi
  done

  echo "Fertig      : ${#finished[@]}"
  if (( ${#finished[@]} > 0 )); then
    printf '  - %s\n' "${finished[@]}"
  fi
  echo "Übersprungen : ${#skipped[@]}"
  if (( ${#skipped[@]} > 0 )); then
    printf '  - %s\n' "${skipped[@]}"
  fi
  echo "Fehlgeschl. : ${#failed[@]}"
  if (( ${#failed[@]} > 0 )); then
    printf '  - %s\n' "${failed[@]}"
  fi

  print_sep "$sep_width"
}

print_summary | tee -a "$RUNNER_LOG"
