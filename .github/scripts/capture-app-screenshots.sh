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
    [ -n "${WM_PID:-}" ] && kill "$WM_PID" 2>/dev/null || true
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
# a minimal WM gives windows sane stacking/focus; harmless if absent
if command -v openbox >/dev/null 2>&1; then
    openbox >/dev/null 2>&1 &
    WM_PID=$!
fi
sleep 1

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

    # --- launch & capture under Xvfb (plain `import`, no teasr needed) ----

    launch_app() {
        setsid nohup dbus-run-session -- "$BIN" ${1:-} >"$WORK_DIR/$app.launch.log" 2>&1 &
        echo $! > "$WORK_DIR/$app.pid"
    }
    stop_apps() {
        local pid
        pid=$(cat "$WORK_DIR/$app.pid" 2>/dev/null || true)
        if [ -n "${pid:-}" ]; then
            # setsid gives the app its own process group: kill the whole tree
            kill -- -"$pid" 2>/dev/null || true
            sleep 1
            kill -9 -- -"$pid" 2>/dev/null || true
            rm -f "$WORK_DIR/$app.pid"
        fi
        sleep 1
    }
    capture_once() {  # $1 = extra flag (empty or --no-sandbox)
        rm -rf "$WORK_DIR/out"
        mkdir -p "$WORK_DIR/out"
        launch_app "${1:-}"
        sleep "$DELAY"

        # find the app's main window: the largest top-level X window (ignores
        # the tiny helper windows from xdg-portals, GTK scratch windows etc.)
        local main_wid
        main_wid=$(find_main_window)
        if [ -n "$main_wid" ]; then
            xdotool windowsize "$main_wid" 1280 800 >/dev/null 2>&1 || true
            sleep 1
            # capturing the window itself crops any blank space around it
        fi

        import -display "$DISPLAY" -window "${main_wid:-root}" \
            "$WORK_DIR/out/$app.png" 2>/dev/null || true
        stop_apps
        if [ -s "$WORK_DIR/out/$app.png" ]; then
            printf '%s' "$WORK_DIR/out/$app.png"
        fi
    }

    find_main_window() {
        local wid size w h area best bestarea
        best=""; bestarea=0
        while read -r wid size rest; do
            w=${size%x*}; h=${size#*x}
            [ -n "${w:-}" ] && [ -n "${h:-}" ] || continue
            area=$((w * h))
            if [ "$area" -gt "$bestarea" ]; then
                bestarea=$area
                best=$wid
            fi
        done < <(xwininfo -root -children 2>/dev/null \
            | grep -E '^     0x[0-9a-f]+ ' \
            | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $1, $i; break } }')
        printf '%s' "$best"
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

    # Chromium/Electron log a distinctive message when they cannot start in
    # the sandbox; adding --no-sandbox to a GTK/Qt app would just be eaten
    # as a positional file argument (e.g. DIE's filename box), so only add
    # the flag when the app's own stderr asks for it.
    sandbox_hint() {
        grep -qi -E 'no-sandbox|suid sandbox|failed to create sandbox|sandbox helper' \
            "$WORK_DIR/$app.launch.log" 2>/dev/null || return 1
    }

    # first try without any flags
    SHOT=$(capture_once "")
    if [ -z "$SHOT" ] || is_blank "$SHOT"; then
        if sandbox_hint; then
            echo "sandbox error detected, retrying with --no-sandbox" | tee -a "$WORK_DIR/log.txt"
            SHOT=$(capture_once "--no-sandbox")
        else
            echo "no/blank capture, retrying" | tee -a "$WORK_DIR/log.txt"
            SHOT=$(capture_once "")
        fi
    fi
    if [ -z "$SHOT" ] || [ ! -s "$SHOT" ]; then
        echo "capture failed ($(tail -n1 "$WORK_DIR/$app.launch.log"))" | tee -a "$WORK_DIR/log.txt"
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