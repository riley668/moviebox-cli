#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRAPER="$SCRIPT_DIR/Moviebox-API/tools/moviebox_scraper.py"
STEM="/tmp/mbmv_$$"
SEARCH_JSON="${STEM}_search.json"
SCRAPE_JSON="${STEM}_scrape.json"
SELECTED="${STEM}_selected"
OUTDIR="./downloads"
ORIGIN="https://movieboxonline.net"

cleanup() {
  rm -f "$SEARCH_JSON" "$SCRAPE_JSON" "$SELECTED"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $0 <title> [resolution] [max-results] [detailPath]

  title        movie title to search for
  resolution   target quality: 360, 480, 720, 1080 (default: 1080)
  max-results  how many search hits to show before auto-picking (default: 1)
  detailPath   skip search and scrape this detailPath directly.
               If omitted you will be prompted to paste a MovieBox link
               (e.g. https://v.moviebox.ph/xxxx) or press Enter to search.

Picks the first movie (subjectType 1) match and downloads it into $OUTDIR.
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }

TITLE="$1"
RES="${2:-1080}"
MAX="${3:-1}"
DETAILPATH="${4:-}"

case "$RES" in
  360|480|720|1080) ;;
  *) echo "error: invalid resolution '$RES' (use 360, 480, 720 or 1080)" >&2; exit 1 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
command -v aria2c  >/dev/null 2>&1 || { echo "error: aria2c not found" >&2; exit 1; }
[[ -f "$SCRAPER" ]] || { echo "error: scraper not found at $SCRAPER" >&2; exit 1; }

resolve_detailpath() {
  local input="$1" page canon
  [[ -z "$input" ]] && return 0
  case "$input" in
    *://*|*/*) ;;
    *) echo "$input"; return 0 ;;
  esac
  if [[ "$input" =~ (videoPlayPage|play|detail)/([A-Za-z0-9_-]+) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { echo "error: curl is required to resolve that link" >&2; return 1; }
  page="$(curl -sL --max-time 30 -A "Mozilla/5.0" "$input")" || { echo "error: could not fetch $input" >&2; return 1; }
  canon="$(printf '%s' "$page" | grep -oE '<link rel="canonical"[^>]*>' | head -1)"
  if [[ "$canon" =~ (play|videoPlayPage|detail)/([A-Za-z0-9_-]+) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  echo "error: could not find a detailPath in $input" >&2
  return 1
}

if [[ -z "$DETAILPATH" ]]; then
  read -rp "[prompt] Paste a MovieBox link or detailPath (or Enter to search): " RAW_INPUT
  if [[ -n "$RAW_INPUT" ]]; then
    DETAILPATH="$(resolve_detailpath "$RAW_INPUT")" || exit 1
    [[ -n "$DETAILPATH" ]] || { echo "error: could not resolve a detailPath from \"$RAW_INPUT\"" >&2; exit 1; }
    echo "[*] Using detailPath: $DETAILPATH"
  fi
fi

if [[ -z "$DETAILPATH" ]]; then
  echo "[*] Searching for \"$TITLE\"..."
  python3 "$SCRAPER" --quiet --search "$TITLE" --limit "$MAX" --out "$SEARCH_JSON"
  parsed="$(python3 - "$SEARCH_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
movies = [d for d in data if d.get("subjectType") == 1]
if not movies:
    sys.stderr.write("error: no movie results\n")
    sys.exit(1)
print(f"{movies[0].get('detailPath', '')}\t{movies[0].get('title', '')}")
PY
)"
  DETAILPATH="${parsed%%$'\t'*}"
  TITLE="${parsed#*$'\t'}"
  [[ -n "$DETAILPATH" ]] || { echo "error: could not determine detailPath" >&2; exit 1; }
  echo "[*] Matched: $TITLE"
fi

echo "[*] Scraping $TITLE at ${RES}p..."
python3 "$SCRAPER" --quiet --movie "$DETAILPATH" --out "$SCRAPE_JSON"

python3 - "$SCRAPE_JSON" "$RES" > "$SELECTED" <<'PY'
import json, re, sys

data = json.load(open(sys.argv[1]))
res = int(sys.argv[2])

if not data:
    sys.stderr.write("error: no data in scrape output\n")
    sys.exit(1)

r = data[0]
title = r.get("title", "Unknown")
safe = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", " ", title)
safe = re.sub(r"\s+", " ", safe).strip()

qs = [q for q in r.get("qualities", [])
      if not q.get("vipLocked") and q.get("url")
      and int(q.get("resolution", 0)) > 0]
if not qs:
    sys.stderr.write("error: no free streams\n")
    sys.exit(1)

exact = next((q for q in qs if int(q.get("resolution", 0)) == res), None)
if exact is None:
    sys.stderr.write(f"  WARN no free {res}p stream, choosing best available\n")
    exact = max(qs, key=lambda q: q["resolution"])

fname = f"{safe}_{exact['resolution']}p.mp4"
print(f"{exact['url']}\t{exact.get('size_mb', 0)}\t{fname}")
PY

IFS=$'\t' read -r URL SIZE FNAME < "$SELECTED"
sizeh="$(python3 - "$SIZE" <<'PY'
import sys
mb = float(sys.argv[1])
print(f"{mb/1024:.2f} GB" if mb >= 1024 else f"{mb:.0f} MB")
PY
)"

mkdir -p "$OUTDIR"
if [[ -f "$OUTDIR/$FNAME" ]]; then
  echo "$FNAME — $sizeh ... skipped, already downloaded ✓"
  exit 0
fi

echo "$FNAME — $sizeh ..."
aria2c -x 8 -s 8 -k 1M -o "$FNAME" --dir "$OUTDIR" --header="Referer: ${ORIGIN}/" "$URL"
echo "$FNAME — $sizeh ... ✓"
echo "[*] Done — downloaded into $OUTDIR"