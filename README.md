# moviebox-cli

Two small Bash wrappers around a single-file, stdlib-only Python scraper for the
MovieBox streaming backend (`h5-api.aoneroom.com`, which powers
`movieboxonline.net` and friends).

- **`mb.sh`** — download a TV season (all episodes, or a limited number).
- **`mb-movie.sh`** — download a single movie.

Both resolve a title (or a pasted MovieBox link / `detailPath`), pick the best
free stream at the requested resolution, and hand the download to
[`aria2c`](https://aria2.github.io/) with the `Referer` header the CDN requires.

> The `mb.sh` and `mb-movie.sh` aliases in a shell config are just shortcuts to
> these scripts, e.g. `alias mb="$PWD/mb.sh"`.

## Requirements

- `bash`
- `python3` (standard library only — no `pip install` needed)
- `aria2c`
- `curl` (optional — only needed to resolve short/pasted links)

## Install

```bash
git clone <your-repo-url> moviebox-cli
cd moviebox-cli
chmod +x mb.sh mb-movie.sh Moviebox-API/tools/moviebox_scraper.py

# optional: make them available anywhere
ln -s "$PWD/mb.sh"       ~/.local/bin/mb
ln -s "$PWD/mb-movie.sh" ~/.local/bin/mb-mov
```

## Usage

### TV shows — `mb.sh`

```text
Usage: mb.sh <title> <season> [resolution] [max-episodes] [detailPath]

  title        TV show title to search for
  season       season number to download (e.g. 1)
  resolution   target quality: 360, 480, 720, 1080 (default: 720)
  max-episodes max episodes to download this season (default: all)
  detailPath   skip search and scrape this detailPath directly.
               If omitted you will be prompted to paste a MovieBox link
               or press Enter to fall back to search.
```

Examples:

```bash
./mb.sh "Breaking Bad" 1                 # S1, 720p, all episodes
./mb.sh "Breaking Bad" 1 1080 3          # S1, 1080p, first 3 episodes
./mb.sh "The Bear" 2 720 "" burn-notice-Sz4KAhTG7H5
```

### Movies — `mb-movie.sh`

```text
Usage: mb-movie.sh <title> [resolution] [max-results] [detailPath]

  title        movie title to search for
  resolution   target quality: 360, 480, 720, 1080 (default: 1080)
  max-results  how many search hits to show before auto-picking (default: 1)
  detailPath   skip search and scrape this detailPath directly.
```

Examples:

```bash
./mb-movie.sh "Oppenheimer"              # 1080p, first match
./mb-movie.sh "Dune Part Two" 720
./mb-movie.sh "Sinners" 1080 5 oppenheimer-Akh5Nrwl7o
```

Output lands in `./downloads/`. Already-downloaded files are skipped, so a
re-run resumes where it left off.

## The scraper

`Moviebox-API/tools/moviebox_scraper.py` is the engine. It is self-contained
and can be used directly:

```bash
python3 Moviebox-API/tools/moviebox_scraper.py --movie oppenheimer-Akh5Nrwl7o
python3 Moviebox-API/tools/moviebox_scraper.py --tv lucifer-UQASHYbVPB2 --seasons 1,2 --max-episodes 5
python3 Moviebox-API/tools/moviebox_scraper.py --search "all american" --limit 5
```

The wrappers keep it at the `Moviebox-API/tools/` path they expect, so no edits
are needed.

## Layout

```text
moviebox-cli/
├── mb.sh                              # TV downloader wrapper
├── mb-movie.sh                        # movie downloader wrapper
├── Moviebox-API/
│   └── tools/
│       └── moviebox_scraper.py        # bundled scraper (stdlib only)
├── .gitignore
└── README.md
```

## Notes / disclaimer

These scripts download from third-party streaming sites. Only use them for
content you are legally entitled to access. The bundled scraper is provided for
educational/interoperability purposes; you are responsible for how you use it.
