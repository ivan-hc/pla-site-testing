#!/usr/bin/env bash
# Find the biggest relevant image for an app from its AM install script's
# SITE value (github owner/repo -> README images, or the project website).
#
# Usage: fetch-site-image.sh <app> <work_dir>
# Prints the path of the downloaded image on success, or nothing.
#
# AppMan's per-app scripts live at
# https://github.com/ivan-hc/AM/blob/main/programs/x86_64/<app> and set
#   SITE="owner/repo"      (github-hosted apps)
#   SITE="https://website" (anything else)
# with optional SITE1/SITE2/... variants for multi-source apps.

set -euo pipefail

APP="$1"
WORK_DIR="${2:-$(mktemp -d)}"
AM_URL="https://raw.githubusercontent.com/ivan-hc/AM/main/programs/x86_64/$APP"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- extract SITE from the AM install script --------------------------------
# take the first SITE= / SITE1= / SITE2= assignment found in the file
site=$(curl -fsSL --max-time 30 -A "$UA" "$AM_URL" 2>/dev/null \
    | grep -oE 'SITE[0-9]*="[^"]*"' | head -n1 \
    | sed -E 's/^SITE[0-9]*="//; s/"$//' || true)
[ -n "${site:-}" ] || { echo "no SITE found for $APP" >&2; exit 1; }
echo "SITE: $site" >&2

candidates=()
if [[ "$site" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    # github repo: scrape the README
    owner=${site%/*}
    repo=${site#*/}
    for readme in README.md readme.md README.MD Readme.md readme.MD; do
        doc=$(curl -fsSL --max-time 30 "https://raw.githubusercontent.com/$owner/$repo/HEAD/$readme" 2>/dev/null) \
            && break
    done
    [ -n "${doc:-}" ] || { echo "no README for $site" >&2; exit 1; }
    # markdown images: ![alt](url)
    mapfile -t cands < <(printf '%s' "$doc" | grep -oE '!\[[^]]*\]\([^)]+\)' \
        | sed -E 's/^!\[[^]]*\]\(//; s/\)$//' || true)
    # html images: <img src="...">
    mapfile -t cands_html < <(printf '%s' "$doc" | grep -oE '<img[^>]+>' \
        | grep -oE 'src="[^"]+"' | sed -E 's/^src="//; s/"$//' || true)
    candidates=("${cands[@]}" "${cands_html[@]}")
    base="https://raw.githubusercontent.com/$owner/$repo/HEAD"
else
    # website: og:image + img tags from the homepage
    page=$(curl -fsSL --max-time 30 -A "$UA" "$site" 2>/dev/null) \
        || { echo "cannot fetch $site" >&2; exit 1; }
    mapfile -t cands_og < <(printf '%s' "$page" | grep -oiE '<meta[^>]+og:image[^>]*>' \
        | grep -oiE '(content|value)="[^"]+"' | sed -E 's/^[^=]+="//; s/"$//' || true)
    mapfile -t cands_img < <(printf '%s' "$page" | grep -oiE '<img[^>]+>' \
        | grep -oiE 'src="[^"]+"' | sed -E 's/^src="//; s/"$//' || true)
    candidates=("${cands_og[@]}" "${cands_img[@]}")
    base="$site"
fi

[ "${#candidates[@]}" -gt 0 ] || { echo "no images found in $site" >&2; exit 1; }

# --- resolve, download, pick the biggest ------------------------------------
seen=()
best=""
bestarea=0
for raw in "${candidates[@]}"; do
    raw=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r')
    [ -n "$raw" ] || continue
    case "$raw" in
        data:*) continue ;;
        //*) url="https:$raw" ;;
        http://*|https://*) url="$raw" ;;
        /*) url="$base$raw" ;;
        *) url="$base/$raw" ;;
    esac
    # strip query/fragment for dedupe, keep for fetch
    key=$(printf '%s' "${url%%[?#]*}")
    case " ${seen[*]} " in *" $key "*) continue ;; esac
    seen+=("$key")
    case "$key" in
        *.svg|*.webp|*.ico|*.gif) continue ;;
    esac
    fname="$TMP/$(basename "$key")"
    curl -fsSL --max-time 30 -A "$UA" -L "$url" -o "$fname" 2>/dev/null || continue
    [ -s "$fname" ] || continue
    # image sanity: dimensions, skip tiny/broken files
    geom=$(identify -format '%w %h' "$fname" 2>/dev/null) || continue
    w=${geom%% *}; h=${geom##* }
    [ "${w:-0}" -ge 200 ] && [ "${h:-0}" -ge 200 ] || continue
    area=$((w * h))
    if [ "$area" -gt "$bestarea" ]; then
        bestarea=$area
        best="$fname"
    fi
done

[ -n "${best:-}" ] || { echo "no usable image (all failed/tiny)" >&2; exit 1; }

ext=$(identify -format '%m' "$best" 2>/dev/null | tr 'A-Z' 'a-z')
case "$ext" in png|jpeg) : ;; *) ext=png ;; esac
dest="$WORK_DIR/site-$APP.$ext"
cp -f "$best" "$dest"
echo "picked $(identify -format '%wx%h' "$dest" 2>/dev/null) image" >&2
printf '%s' "$dest"