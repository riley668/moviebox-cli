#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRAPER="$SCRIPT_DIR/Moviebox-API/tools/moviebox_scraper.py"
STEM="/tmp/mb_$$"
SEARCH_JSON="${STEM}_search.json"
SCRAPE_JSON="${STEM}_scrape.json"
EPISODES_TSV="${STEM}_episodes.tsv"
OUTDIR="./downloads"
ORIGIN="https://movieboxonline.net"

cleanup() {
  rm -f "$SEARCH_JSON" "$SCRAPE_JSON" "$EPISODES_TSV"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $0 <title> <season> [resolution] [max-episodes] [detailPath]

  title        TV show title to search for
  season       season number to download (e.g. 1)
  resolution   target quality: 360, 480, 720, 1080 (default: 720)
  max-episodes max episodes to download this season (default: all)
  detailPath   skip search and scrape this detailPath directly.
               If omitted you will be prompted to paste a MovieBox link
               (e.g. https://v.moviebox.ph/xxxx or movieboxonline.net/play/slug)
               or press Enter to fall back to search.

Depends on: python3, aria2c, $SCRAPER, and optionally curl (for short links)
EOF
}

resolve_detailpath() {
  local input="$1" page canon
  [[ -z "$input" ]] && return 0
  case "$input" in
    *://*|*/*) ;;  # it's a URL or path
    *) echo "$input"; return 0 ;;  # bare detailPath like burn-notice-Sz4KAhTG7H5
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

[[ $# -ge 2 ]] || { usage; exit 1; }

TITLE="$1"
SEASON="$2"
RES="${3:-720}"
MAXEP="${4:-}"
DETAILPATH="${5:-}"

case "$RES" in
  360|480|720|1080) ;;
  *) echo "error: invalid resolution '$RES' (use 360, 480, 720 or 1080)" >&2; exit 1 ;;
esac

[[ "$SEASON" =~ ^[0-9]+$ ]] || { echo "error: season must be a number" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
command -v aria2c  >/dev/null 2>&1 || { echo "error: aria2c not found" >&2; exit 1; }
[[ -f "$SCRAPER" ]] || { echo "error: scraper not found at $SCRAPER" >&2; exit 1; }

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
  python3 "$SCRAPER" --quiet --search "$TITLE" --limit 5 --out "$SEARCH_JSON"
  parsed="$(python3 - "$SEARCH_JSON" "$TITLE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if not data:
    sys.stderr.write(f"error: no results for \"{sys.argv[2]}\"\n")
    sys.exit(1)
r = data[0]
print(f"{r.get('detailPath', '')}\t{r.get('title', '')}")
PY
)"
  DETAILPATH="${parsed%%$'\t'*}"
  TITLE="${parsed#*$'\t'}"
  [[ -n "$DETAILPATH" ]] || { echo "error: could not determine detailPath from search results" >&2; exit 1; }
  echo "[*] Matched: $TITLE"
fi

echo "[*] Scraping $TITLE season $SEASON at ${RES}p..."
MAXEP_ARGS=()
if [[ -n "$MAXEP" ]]; then
  MAXEP_ARGS=(--max-episodes "$MAXEP")
else
  MAXEP_ARGS=(--max-episodes 0)
fi
python3 "$SCRAPER" --quiet --tv "$DETAILPATH" --seasons "$SEASON" --delay 5 "${MAXEP_ARGS[@]}" --out "$SCRAPE_JSON"

python3 - "$SCRAPE_JSON" "$RES" "$SEASON" > "$EPISODES_TSV" <<'PY'
import json, re, sys

data = json.load(open(sys.argv[1]))
res, season = int(sys.argv[2]), int(sys.argv[3])

if not data:
    sys.stderr.write("error: no data in scrape output\n")
    sys.exit(1)

r = data[0]
title = r.get("title", "Unknown")
safe = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", " ", title)
safe = re.sub(r"\s+", " ", safe).strip()
found = False

for s in r.get("seasons", []):
    if int(s.get("season", 0)) != season:
        continue
    for ep in s.get("episodes", []):
        epnum = int(ep.get("episode", 0))
        match = next((q for q in ep.get("qualities", [])
                      if int(q.get("resolution", 0)) == res
                      and not q.get("vipLocked") and q.get("url")), None)
        if match is None:
            sys.stderr.write(f"  WARN S{season:02d}E{epnum:03d}: no free {res}p stream, skipping\n")
            continue
        found = True
        fname = f"{safe} S{season:02d}E{epnum:03d}_{res}p.mp4"
        print(f"{season}\t{epnum}\t{match['url']}\t{match.get('size_mb', 0)}\t{fname}")

if not found:
    sys.stderr.write(f"error: no free {res}p stream found for any episode of season {season}\n")
    sys.exit(1)
PY

mkdir -p "$OUTDIR"
total=$(wc -l < "$EPISODES_TSV" | tr -d ' ')

i=0
while IFS=$'\t' read -r se ep url size filename; do
  i=$((i + 1))
  printf -v label "S%02dE%03d" "$se" "$ep"
  sizeh="$(python3 - "$size" <<'PY'
import sys
mb = float(sys.argv[1])
print(f"{mb/1024:.2f} GB" if mb >= 1024 else f"{mb:.0f} MB")
PY
)"
  if [[ -f "$OUTDIR/$filename" ]]; then
    echo "[$i/$total] $label — $sizeh ... skipped, already downloaded ✓"
    continue
  fi
  echo "[$i/$total] $label — $sizeh ..."
  aria2c -x 8 -s 8 -k 1M -o "$filename" --dir "$OUTDIR" --header="Referer: ${ORIGIN}/" "$url"
  echo "[$i/$total] $label — $sizeh ... ✓"
  [[ $i -lt $total ]] && sleep 3
done < "$EPISODES_TSV"

echo "[*] Done — $total episode(s) processed into $OUTDIR"