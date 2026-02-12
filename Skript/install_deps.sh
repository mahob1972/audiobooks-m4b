#!/usr/bin/env bash
set -euo pipefail

# Install/check dependencies for the Audiobooks m4b project on macOS (Homebrew).
# - Verifies Homebrew, ffmpeg (prefer libfdk_aac), AtomicParsley, gsed, gsort.
# - Offers interactive installation/switch to ffmpeg with libfdk_aac from the
#   homebrew-ffmpeg tap when missing.
# - Creates project directories (rohdaten, ausgabe, logs).

export LC_ALL=${LC_ALL:-C.UTF-8}
export LANG=${LANG:-C.UTF-8}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Default Ziel-Verzeichnis (falls per Remote-Bootstrap genutzt)
DEFAULT_DEST="$HOME/Documents/Audiobooks"
PROJECT_DIR="${PROJECT_DIR:-}"
PROJECT_DIR="${PROJECT_DIR:-$DEFAULT_DEST}"

INPUT_ROOT="$PROJECT_DIR/rohdaten"
OUTPUT_ROOT="$PROJECT_DIR/ausgabe"
LOG_ROOT="$PROJECT_DIR/logs"

YES_ALL=0
NO_OPTIONAL=0
KEEP_CORE_FFMPEG=0
GITHUB_REPO=""    # z.B. "username/audiobooks-m4b"
GITHUB_BRANCH="main"
DO_FETCH=0
DEST_DIR="$PROJECT_DIR"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES_ALL=1 ;;
    --no-optional) NO_OPTIONAL=1 ;;
    --keep-core-ffmpeg) KEEP_CORE_FFMPEG=1 ;;
    --github)
      GITHUB_REPO="$2"; shift 2 ;;
    --branch)
      GITHUB_BRANCH="$2"; shift 2 ;;
    --dest)
      DEST_DIR="$2"; PROJECT_DIR="$2"; shift 2 ;;
    --fetch)
      DO_FETCH=1; shift ;;
    -h|--help)
      cat <<HELP
Usage: $(basename "$0") [options]

Options:
  -y, --yes            Auto-accept recommended installations.
  --no-optional        Skip optional tools (e.g., mpg123).
  --keep-core-ffmpeg   Behalte vorhandenes ffmpeg aus homebrew-core (kein Tap-Switch).
  --github OWNER/REPO  GitHub Repo, aus dem Projektdateien bezogen werden sollen.
  --branch NAME        Branch/Tag (Default: main).
  --dest PATH          Ziel-Ordner (Default: $DEFAULT_DEST).
  --fetch              Projektdateien aus GitHub in --dest holen (git/curl).
  -h, --help           Show this help.

This script targets macOS + Homebrew.
HELP
      exit 0 ;;
  esac
done

confirm() {
  local prompt="$1"
  if (( YES_ALL )); then return 0; fi
  read -r -p "$prompt [y/N] " ans || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

msg() { printf "\033[36m%s\033[0m\n" "$*"; }
ok() { printf "\033[32m✔ %s\033[0m\n" "$*"; }
warn() { printf "\033[33m⚠ %s\033[0m\n" "$*"; }
err() { printf "\033[31m✖ %s\033[0m\n" "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "Dieses Script ist für macOS (Homebrew) ausgelegt."
fi

if ! have brew; then
  warn "Homebrew nicht gefunden. Installationsanleitung: https://brew.sh"
  if confirm "Homebrew jetzt installieren? (öffnet offiziellen Installer)"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$($(command -v brew) shellenv)"
  else
    err "Ohne Homebrew kann ich Abhängigkeiten nicht automatisch installieren."
  fi
fi

# ---------------- Bootstrap aus GitHub (optional) ----------------
sync_from_github() {
  local repo="$1" branch="$2" dest="$3"
  if [[ -z "$repo" ]]; then
    err "--github OWNER/REPO nicht gesetzt; kann nicht aus GitHub holen."; return 1
  fi
  mkdir -p "$dest"
  if have git; then
    msg "Hole Projekt via git: $repo@$branch → $dest"
    if [[ -d "$dest/.git" ]]; then
      (cd "$dest" && git fetch --depth 1 origin "$branch" && git reset --hard "origin/$branch")
    else
      git clone --depth 1 -b "$branch" "https://github.com/$repo.git" "$dest"
    fi
  else
    msg "Hole Projekt-Archiv (ohne git): $repo@$branch"
    local tarurl="https://codeload.github.com/$repo/tar.gz/$branch"
    local tmpdir; tmpdir="$(mktemp -d)"
    curl -fsSL "$tarurl" -o "$tmpdir/repo.tar.gz"
    mkdir -p "$tmpdir/ex"
    tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir/ex"
    # Der Extraktionsordner hat den Namen repo-<branch>
    local srcdir; srcdir="$(find "$tmpdir/ex" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    rsync -a "$srcdir"/ "$dest"/
    rm -rf "$tmpdir"
  fi
}

if (( DO_FETCH )); then
  sync_from_github "$GITHUB_REPO" "$GITHUB_BRANCH" "$DEST_DIR"
  ok "Projektdateien synchronisiert: $DEST_DIR"
fi

# Ensure project directories (nach optionalem Fetch, da $PROJECT_DIR ggf. neu ist)
mkdir -p "$INPUT_ROOT" "$OUTPUT_ROOT" "$LOG_ROOT"
ok "Projektordner geprüft/angelegt: rohdaten, ausgabe, logs"

# ---- ffmpeg (prefer libfdk_aac) ----
FFMPEG_OK=0
if have ffmpeg; then
  if ffmpeg -hide_banner -v error -encoders | grep -q " libfdk_aac "; then
    ok "ffmpeg gefunden (mit libfdk_aac)"
    FFMPEG_OK=1
  else
    warn "ffmpeg gefunden, aber ohne libfdk_aac."
    if (( KEEP_CORE_FFMPEG )); then
      warn "--keep-core-ffmpeg aktiv: überspringe Tap-Switch."
    else
      if confirm "ffmpeg auf Tap-Version mit libfdk_aac umstellen?"; then
        brew tap homebrew-ffmpeg/ffmpeg || true
        # Entferne evtl. vorhandenes core-ffmpeg
        if brew list --versions ffmpeg >/dev/null 2>&1; then
          brew uninstall --ignore-dependencies ffmpeg || true
        fi
        brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac
        if ffmpeg -hide_banner -v error -encoders | grep -q " libfdk_aac "; then
          ok "ffmpeg jetzt mit libfdk_aac installiert"
          FFMPEG_OK=1
        else
          warn "libfdk_aac weiterhin nicht sichtbar."
        fi
      fi
    fi
  fi
else
  warn "ffmpeg nicht gefunden."
  if confirm "ffmpeg (mit libfdk_aac) installieren?"; then
    brew tap homebrew-ffmpeg/ffmpeg || true
    brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac
    if ffmpeg -hide_banner -v error -encoders | grep -q " libfdk_aac "; then
      ok "ffmpeg installiert (libfdk_aac verfügbar)"; FFMPEG_OK=1
    else
      warn "ffmpeg installiert, aber libfdk_aac nicht sichtbar."
    fi
  fi
fi

# ---- AtomicParsley ----
if have AtomicParsley; then
  ok "AtomicParsley gefunden"
else
  warn "AtomicParsley nicht gefunden"
  if confirm "AtomicParsley installieren?"; then
    brew install atomicparsley
    ok "AtomicParsley installiert"
  fi
fi

# ---- gsed (gnu-sed) ----
if have gsed; then
  ok "gsed gefunden"
else
  warn "gsed nicht gefunden"
  if confirm "gnu-sed (gsed) installieren?"; then
    brew install gnu-sed
    ok "gnu-sed installiert"
  fi
fi

# ---- gsort (coreutils) ----
if have gsort; then
  ok "gsort gefunden"
else
  warn "gsort nicht gefunden"
  if confirm "coreutils (gsort) installieren?"; then
    brew install coreutils
    ok "coreutils installiert"
  fi
fi

# ---- Optional: mpg123 ----
if (( NO_OPTIONAL )); then
  warn "Optionale Tools übersprungen (--no-optional)."
else
  if have mpg123; then
    ok "mpg123 gefunden (optional)"
  else
    warn "mpg123 nicht gefunden (optional, schnellere/robustere MP3→WAV)"
    if confirm "mpg123 installieren?"; then
      brew install mpg123
      ok "mpg123 installiert"
    fi
  fi
fi

echo ""
msg "Zusammenfassung:"
echo "  Projektordner : $PROJECT_DIR"
echo "  Eingabe       : $INPUT_ROOT"
echo "  Ausgabe       : $OUTPUT_ROOT"
echo "  Logs          : $LOG_ROOT"
if (( DO_FETCH )); then
  echo "  Quelle (GitHub): ${GITHUB_REPO:-(nicht gesetzt)} @ ${GITHUB_BRANCH}"
fi

echo "  ffmpeg        : $(command -v ffmpeg >/dev/null 2>&1 && echo vorhanden || echo fehlt)"
echo "  AtomicParsley : $(command -v AtomicParsley >/dev/null 2>&1 && echo vorhanden || echo fehlt)"
echo "  gsed          : $(command -v gsed >/dev/null 2>&1 && echo vorhanden || echo fehlt)"
echo "  gsort         : $(command -v gsort >/dev/null 2>&1 && echo vorhanden || echo fehlt)"
echo "  mpg123 (opt.) : $(command -v mpg123 >/dev/null 2>&1 && echo vorhanden || echo fehlt)"

if (( ! FFMPEG_OK )); then
  warn "Hinweis: libfdk_aac wurde nicht gefunden. Das Skript fällt dann auf 'aac' oder 'aac_at' zurück."
fi

ok "Installationsprüfung abgeschlossen."
