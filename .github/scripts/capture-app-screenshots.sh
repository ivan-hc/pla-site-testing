#!/usr/bin/env bash
# Capture screenshots for catalog apps missing them and file one issue per app.
#
# Environment:
#   REPO      GitHub repo in owner/name form (default: current repo)
#   MAX_APPS  how many apps to process in this run (default: 10)
#   DELAY     seconds to wait for each app window (default: 8)
#   SHUFFLE   any value -> randomize app order instead of alphabetical
#   GITHUB_STEP_SUMMARY  set by GitHub Actions (optional, for the run summary)

set -euo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
MAX_APPS="${MAX_APPS:-10}"
DELAY="${DELAY:-8}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${RUNNER_TEMP:-/tmp}/app-capture"
RELEASE_TAG="screenshots-captured"

mkdir -p "$WORK_DIR/out"
export PATH="$HOME/.local/bin:$PATH"

# Friendly runtime settings for GUI apps under a virtual display.
export APPIMAGE_EXTRACT_AND_RUN=1
export ELECTRON_DISABLE_SANDBOX=1
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}
export DISPLAY="${DISPLAY:-:99}"

results=()
cleanup() {
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- candidate selection ----------------------------------------------------
mapfile -t APPS < <(
    python3 "$SCRIPT_DIR/select-apps-missing-screenshots.py" "${GITHUB_WORKSPACE:-$PWD}/apps" "${SHUFFLE:+shuffle}"
)
echo "apps needing screenshots: ${#APPS[@]} (processing up to $MAX_APPS)" | tee -a "$WORK_DIR/log.txt"

# --- image hosting via a dedicated release ----------------------------------
if ! gh release view "$RELEASE_TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" -R "$REPO" \
        --latest=false --title "Auto-captured screenshots" \
        --notes "Screenshots captured automatically and referenced from screenshot-request issues." >/dev/null
fi

# --- virtual display --------------------------------------------------------
Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
sleep 2

count=0
for app in "${APPS[@]}"; do
    count=$((count + 1))
    if [ "$count" -gt "$MAX_APPS" ]; then
        echo "[$count/$MAX_APPS] reached max, stopping" | tee -a "$WORK_DIR/log.txt"
        break
    fi
    echo "===== [$count/$MAX_APPS] $app =====" | tee -a "$WORK_DIR/log.txt"

    # skip apps that already have an open screenshot-request issue
    open_issues=$(gh issue list -R "$REPO" --state open \
        --search "in:title \"Screenshot for $app\"" --json number -q 'length' 2>/dev/null || echo 0)
    if [ "${open_issues:-0}" -ge 1 ]; then
        echo "skip: 'Screenshot for $app' issue already open" | tee -a "$WORK_DIR/log.txt"
        results+=("SKIP $app (issue already open)")
        continue
    fi

    # install via AppMan (local, no root)
    if ! timeout 900 env appman_location="$HOME/Applications" \
        appman -y -i --user "$app" >"$WORK_DIR/$app.install.log" 2>&1; then
        echo "install failed ($(tail -n1 "$WORK_DIR/$app.install.log"))" | tee -a "$WORK_DIR/log.txt"
        results+=("FAIL $app (install)")
        continue
    fi

    # locate the executable: launcher symlink first, then .desktop Exec, then app dir
    BIN=""
    if [ -x "$HOME/.local/bin/$app" ]; then
        BIN="$HOME/.local/bin/$app"
    elif [ -f "$HOME/.local/share/applications/$app-AM.desktop" ]; then
        BIN=$(grep -m1 '^Exec=' "$HOME/.local/share/applications/$app-AM.desktop" \
            | sed 's/^Exec=//; s/ *%[uUfF]//g' | tr -d '\r' | xargs)
    else
        BIN=$(find "$HOME/Applications/$app" -maxdepth 1 -type f -perm -u+x 2>/dev/null | head -n1)
    fi
    if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
        echo "could not locate executable after install" | tee -a "$WORK_DIR/log.txt"
        results+=("FAIL $app (no binary)")
        continue
    fi

    # capture with teasr (screen mode, window chrome).
    # window = "$app" crops to the app's own window instead of the full
    # 1280x800 display, which is what was causing the empty space around
    # the app content. teasr matches window titles case-insensitively by
    # substring, so this works whenever the window title contains the app
    # id; if it doesn't, write_config_fullscreen below is the fallback.
    write_config() {
        cat > "$WORK_DIR/$app.toml" <<EOF
[output]
dir = "$WORK_DIR/out"
formats = [{ output_type = "png" }]

[[scenes]]
type = "screen"
name = "$app"
title = "$app"
window = "$app"
setup = "$1"
delay = $((DELAY * 1000))

[[scenes.interactions]]
type = "snapshot"
EOF
    }
    # Fallback used only if window-targeted capture never finds a match:
    # same as before, full display, at least gets *a* screenshot.
    write_config_fullscreen() {
        cat > "$WORK_DIR/$app.toml" <<EOF
[output]
dir = "$WORK_DIR/out"
formats = [{ output_type = "png" }]

[[scenes]]
type = "screen"
name = "$app"
title = "$app"
setup = "$1"
delay = $((DELAY * 1000))

[[scenes.interactions]]
type = "snapshot"
EOF
    }
    run_teasr() {
        timeout 150 teasr run -c "$WORK_DIR/$app.toml" -o "$WORK_DIR/out" \
            --scene-timeout 90 >"$WORK_DIR/$app.capture.log" 2>&1
    }
    shot_path() {
        # out/ is wiped right before every capture attempt (see below), so
        # anything here belongs to *this* app/attempt -- no name matching needed.
        ls -t "$WORK_DIR"/out/*.png 2>/dev/null | head -n1
    }
    is_blank() {
        if command -v identify >/dev/null 2>&1; then
            local colors
            colors=$(identify -format '%k' "$1" 2>/dev/null || echo 999)
            [ "${colors:-999}" -lt 16 ]
        else
            return 1
        fi
    }

    SHOT=""
    rm -rf "$WORK_DIR/out"; mkdir -p "$WORK_DIR/out"
    write_config "nohup dbus-run-session -- $BIN >/dev/null 2>&1 &"
    if run_teasr; then
        SHOT=$(shot_path)
    fi
    if [ -z "$SHOT" ] || [ ! -s "$SHOT" ] || is_blank "$SHOT"; then
        # many Electron/Chromium apps refuse to run without --no-sandbox
        echo "no/blank capture, retrying with --no-sandbox" | tee -a "$WORK_DIR/log.txt"
        rm -rf "$WORK_DIR/out"; mkdir -p "$WORK_DIR/out"
        write_config "nohup dbus-run-session -- $BIN --no-sandbox >/dev/null 2>&1 &"
        if run_teasr; then
            SHOT=$(shot_path)
        fi
    fi
    if [ -z "$SHOT" ] || [ ! -s "$SHOT" ] || is_blank "$SHOT"; then
        # window title didn't match "$app" (common for apps whose window
        # title differs from the AM app id) -- fall back to full display
        # rather than failing the app outright.
        echo "no window match, falling back to full-display capture" | tee -a "$WORK_DIR/log.txt"
        rm -rf "$WORK_DIR/out"; mkdir -p "$WORK_DIR/out"
        write_config_fullscreen "nohup dbus-run-session -- $BIN --no-sandbox >/dev/null 2>&1 &"
        if run_teasr; then
            SHOT=$(shot_path)
        fi
    fi
    if [ -z "$SHOT" ] || [ ! -s "$SHOT" ]; then
        echo "capture failed ($(tail -n1 "$WORK_DIR/$app.capture.log"))" | tee -a "$WORK_DIR/log.txt"
        results+=("FAIL $app (capture)")
        continue
    fi
    if is_blank "$SHOT"; then
        echo "capture looks blank, skipping" | tee -a "$WORK_DIR/log.txt"
        results+=("SKIP $app (blank capture)")
        continue
    fi

    # shrink for embedding in issues
    convert "$SHOT" -resize '1280x800>' -strip "${SHOT}.small.png"
    mv -f "${SHOT}.small.png" "$SHOT"

    gh release upload "$RELEASE_TAG" "$SHOT" -R "$REPO" --clobber >/dev/null 2>&1
    img_url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$(basename "$SHOT")"

    cat > "$WORK_DIR/$app.body.md" <<EOF
This issue was opened automatically after capturing a screenshot of **$app** running
under a virtual display in CI.

![screenshot of $app]($img_url)

**Checklist**
- [ ] review the screenshot above
- [ ] add it to the _SCREENSHOTS_ line in [apps/$app](../../blob/main/apps/$app)
- [ ] close this issue when done

_Reproduction (AppImage/AppMan):_
\`\`\`
appman -i --user $app
\`\`\`
EOF

    gh issue create -R "$REPO" --title "Screenshot for $app" --body-file "$WORK_DIR/$app.body.md" \
        >> "$WORK_DIR/issues.log" 2>&1
    results+=("OK $app")
done

# --- run summary -------------------------------------------------------------
{ echo ""
  echo "## Screenshot capture results"
  echo ""
  echo "| result |"
  echo "|---|"
  printf '| %s |\n' "${results[@]:-(no results)}"
  echo ""
  echo "Logs: ${GITHUB_SERVER_URL:-github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-this run}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
printf '%s\n' "${results[@]:-(no results)}"