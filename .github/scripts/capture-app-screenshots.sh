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
DELAY="${DELAY:-20}"
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
# no sound hardware in CI: SDL apps (games etc.) abort at startup otherwise
export SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-dummy}
export DISPLAY="${DISPLAY:-:99}"

results=()
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$WORK_DIR/log.txt"; }
cleanup() {
    [ -n "${WM_PID:-}" ] && kill "$WM_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- candidate selection ----------------------------------------------------
mapfile -t APPS < <(
    python3 "$SCRIPT_DIR/select-apps-missing-screenshots.py" "${GITHUB_WORKSPACE:-$PWD}/apps" "${SHUFFLE:+shuffle}"
)
log "apps needing screenshots: ${#APPS[@]} (processing up to $MAX_APPS)"

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
LAUNCH_PGID=0
for app in "${APPS[@]}"; do
    count=$((count + 1))
    if [ "$count" -gt "$MAX_APPS" ]; then
        log "[$count/$MAX_APPS] reached max, stopping"
        break
    fi
    log "===== [$count/$MAX_APPS] $app ====="

    # skip apps that already have an open screenshot-request issue
    open_issues=$(gh issue list -R "$REPO" --state open \
        --search "in:title \"Screenshot for $app\"" --json number -q 'length' 2>/dev/null || echo 0)
    if [ "${open_issues:-0}" -ge 1 ]; then
        log "SKIP: 'Screenshot for $app' issue already open"
        results+=("SKIP $app (issue already open)")
        continue
    fi

    # install via AppMan (local, no root)
    log "installing $app via appman..."
    if ! timeout 900 env appman_location="$HOME/Applications" \
        appman -y -i --user "$app" >"$WORK_DIR/$app.install.log" 2>&1; then
        log "install failed - last lines from $app.install.log:"
        tail -n 15 "$WORK_DIR/$app.install.log" | tee -a "$WORK_DIR/log.txt" >&2
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
        log "could not locate executable after install
  - ~/.local/bin/$app: $([ -e "$HOME/.local/bin/$app" ] && echo 'exists' || echo 'missing')"
        log "  - contents of $HOME/Applications/$app:" 
        ls -la "$HOME/Applications/$app" 2>/dev/null | tee -a "$WORK_DIR/log.txt" >&2 || true
        results+=("FAIL $app (no binary)")
        continue
    fi
    log "BIN=$BIN"

    # --- site image from the app's own website/repo (independent of capture) --
    SITE_IMG=""
    if SITE_IMG=$(timeout 80 bash "$SCRIPT_DIR/fetch-site-image.sh" "$app" "$WORK_DIR" \
        2>"$WORK_DIR/$app.site.log"); then
        if [ -s "$SITE_IMG" ]; then
            log "site image: $SITE_IMG ($(identify -format '%wx%h' "$SITE_IMG" 2>/dev/null || echo '?'))"
        else
            SITE_IMG=""
        fi
    else
        SITE_IMG=""
        log "no site image ($(tail -n1 "$WORK_DIR/$app.site.log" 2>/dev/null || echo '?') )"
    fi

    # --- launch & capture under Xvfb (plain `import`, no teasr needed) ----

    launch_app() {
        # some apps refuse to start when their config dir is missing (e.g.
        # deskthing cannot create ~/.config/<app>/logs); make it exist first
        mkdir -p "$HOME/.config/$app" 2>/dev/null || true
        setsid nohup dbus-run-session -- "$BIN" ${1:-} >"$WORK_DIR/$app.launch.log" 2>&1 &
        echo $! > "$WORK_DIR/$app.pid"
        LAUNCH_PGID=$!
    }
    stop_apps() {
        local pid child
        pid=$(cat "$WORK_DIR/$app.pid" 2>/dev/null || true)
        if [ -n "${pid:-}" ]; then
            # TERM the app itself first; killing the whole group at once also
            # takes out dbus-run-session, which makes Chromium/Electron report
            # "D-Bus connection was disconnected" FATAL spam in the launch log
            child=$(pgrep -P "$pid" 2>/dev/null | tail -n1 || true)
            [ -n "${child:-}" ] && kill "$child" 2>/dev/null || true
            sleep 1
            # setsid gives the app its own process group: kill the whole tree
            kill -- -"$pid" 2>/dev/null || true
            sleep 1
            kill -9 -- -"$pid" 2>/dev/null || true
            rm -f "$WORK_DIR/$app.pid"
        fi
        # kill any orphaned X clients left behind by a hardened app (they
        # daemonize out of our process group, keep their windows mapped, and
        # then get mistaken for the *next* app's window)
        local wid wpid
        while read -r wid size rest; do
            wpid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
            [ -n "${wpid:-}" ] || continue
            if [ "${wpid:-0}" -ne "${LAUNCH_PGID:-0}" ] && kill -0 "$wpid" 2>/dev/null; then
                kill -9 "$wpid" 2>/dev/null || true
            fi
        done < <(xwininfo -root -children 2>/dev/null \
            | grep -E '^     0x[0-9a-f]+ ' \
            | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $1, $i; break } }')
        sleep 1
    }
    capture_once() {  # $1 = extra args for the app
        rm -rf "$WORK_DIR/out"
        mkdir -p "$WORK_DIR/out"
        launch_app "${1:-}"
        sleep "$DELAY"

        # find the app's main window: the largest top-level X window (ignores
        # the tiny helper windows from xdg-portals, GTK scratch windows etc.)
        local main_wid
        main_wid=$(find_main_window)
        if [ -n "$main_wid" ]; then
            log "  window found: $main_wid"
            xdotool windowsize "$main_wid" 1280 800 >/dev/null 2>&1 || \
                log "  windowsize rejected (fixed-size window)"
            sleep 1
            # capturing the window itself crops any blank space around it
        else
            log "  no window found on display, capturing full root"
            xwininfo -root -tree 2>/dev/null | tail -n 15 > "$WORK_DIR/$app.tree.log" || true
        fi

        # window-targeted capture; fall back to root if it yields nothing
        import -display "$DISPLAY" -window "${main_wid:-root}" \
            "$WORK_DIR/out/$app.png" >"$WORK_DIR/$app.import.log" 2>&1 || true
        if [ ! -s "$WORK_DIR/out/$app.png" ]; then
            log "  window capture empty, falling back to root"
            import -display "$DISPLAY" -window root \
                "$WORK_DIR/out/$app.png" >>"$WORK_DIR/$app.import.log" 2>&1 || true
        fi
        stop_apps
        if [ -s "$WORK_DIR/out/$app.png" ]; then
            printf '%s' "$WORK_DIR/out/$app.png"
        fi
    }

    find_main_window() {
        # largest *viewable* top-level window; prefers one owned by this
        # app's process group (if discoverable) but falls back to any
        # viewable window -- strict PID filtering rejects real apps (Qt
        # helper processes, python wrappers, zenity dialogs) without
        # _NET_WM_PID or running in a different process group. Stale
        # windows are instead killed between apps in stop_apps.
        local wid size w h area best bestarea fallback fallarea wpid pgid
        best=""; bestarea=0
        fallback=""; fallarea=0
        while read -r wid size rest; do
            w=${size%x*}; h=${size#*x}
            [ -n "${w:-}" ] && [ -n "${h:-}" ] || continue
            area=$((w * h))
            # must be mapped+viewable: xwininfo -children lists windows that
            # are not currently viewable too, and import fails on those
            xwininfo -id "$wid" 2>/dev/null | grep -q 'Map State: IsViewable' || continue
            # remember any viewable window as fallback
            if [ "$area" -gt "$fallarea" ]; then
                fallarea=$area
                fallback=$wid
            fi
            # tightly-scoped preference: window owned by this app's pgid
            wpid=$(xprop -id "$wid" _NET_WM_PID 2>/dev/null | grep -oE '[0-9]+$')
            [ -n "${wpid:-}" ] || continue
            pgid=$(ps -o pgid= -p "$wpid" 2>/dev/null | tr -d ' ')
            [ "$pgid" = "$LAUNCH_PGID" ] || continue
            if [ "$area" -gt "$bestarea" ]; then
                bestarea=$area
                best=$wid
            fi
        done < <(xwininfo -root -children 2>/dev/null \
            | grep -E '^     0x[0-9a-f]+ ' \
            | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+/) { print $1, $i; break } }')
        printf '%s' "${best:-$fallback}"
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
    # headless Xvfb has no GPU: Chromium/Electron often abort with GPU
    # process failures -- needs --disable-gpu (and --no-sandbox too, same
    # stderr-asking-for-it rationale as above)
    gpu_hint() {
        grep -qi -E 'gpu process|gpu.*(fail|usable|crash)|vk[A-Z][a-z]+\(|vulkan|dri3|libOpenGL|libEGL' \
            "$WORK_DIR/$app.launch.log" 2>/dev/null || return 1
    }

    # first try without any flags
    SHOT=""
    SHOT_A=""
    site_url=""
    SHOT=$(capture_once "")
    if [ -z "$SHOT" ] || is_blank "$SHOT"; then
        if sandbox_hint; then
            log "sandbox error detected, retrying with --no-sandbox"
            SHOT=$(capture_once "--no-sandbox")
        elif gpu_hint; then
            log "GPU error detected, retrying with --no-sandbox --disable-gpu"
            SHOT=$(capture_once "--no-sandbox --disable-gpu")
        else
            log "no/blank capture, retrying"
            SHOT=$(capture_once "")
        fi
    fi
    if [ -z "$SHOT" ] || [ ! -s "$SHOT" ]; then
        log "capture failed - last lines from $app.launch.log:"
        tail -n 15 "$WORK_DIR/$app.launch.log" | tee -a "$WORK_DIR/log.txt" >&2 || true
        if [ -s "$WORK_DIR/$app.import.log" ]; then
            log "import errors from $app.import.log:"
            tail -n 5 "$WORK_DIR/$app.import.log" | tee -a "$WORK_DIR/log.txt" >&2 || true
        fi
        if [ -s "$WORK_DIR/$app.tree.log" ]; then
            log "window tree when no window found:"
            cat "$WORK_DIR/$app.tree.log" | tee -a "$WORK_DIR/log.txt" >&2 || true
        fi
        if [ -n "$SITE_IMG" ]; then
            log "capture failed, falling back to site image only"
            SHOT_A="$SITE_IMG"
            SITE_IMG=""
        else
            results+=("FAIL $app (capture)")
            continue
        fi
    elif is_blank "$SHOT"; then
        log "capture looks blank, skipping ($(identify -format '%k colors' "$SHOT" 2>/dev/null || echo '?') on $SHOT)"
        if [ -n "$SITE_IMG" ]; then
            log "blank capture, falling back to site image only"
            SHOT_A="$SITE_IMG"
            SITE_IMG=""
        else
            results+=("SKIP $app (blank capture)")
            continue
        fi
    else
        SHOT_A="$SHOT"
    fi
    log "captured $SHOT_A ($(identify -format '%wx%h, %k colors' "$SHOT_A" 2>/dev/null || echo 'size?'))"

    # shrink for embedding in issues (only for real captures)
    if [ "$SHOT_A" = "$SHOT" ]; then
        convert "$SHOT_A" -resize '1280x800>' -strip "${SHOT_A}.small.png" 2>&1 | tee -a "$WORK_DIR/log.txt" >&2 || true
        mv -f "${SHOT_A}.small.png" "$SHOT_A" 2>/dev/null || true
    fi

    if ! gh release upload "$RELEASE_TAG" "$SHOT_A" -R "$REPO" --clobber >/dev/null 2>&1; then
        log "release upload failed for $SHOT_A"
        results+=("FAIL $app (upload)")
        continue
    fi
    img_url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$(basename "$SHOT_A")"

    if [ -n "$SITE_IMG" ]; then
        if ! gh release upload "$RELEASE_TAG" "$SITE_IMG" -R "$REPO" --clobber >/dev/null 2>&1; then
            log "release upload failed for site image $SITE_IMG"
        else
            site_url="https://github.com/$REPO/releases/download/$RELEASE_TAG/$(basename "$SITE_IMG")"
        fi
    fi

    # build the issue body; embed whatever images we have
    {
        cat <<EOF
This issue was opened automatically for **$app**, which is missing a screenshot
in the catalog.

EOF
        if [ -n "$SITE_IMG" ] && [ -n "$site_url" ]; then
            printf '![captured screenshot of %s](%s)\n\n![site image of %s](%s)\n\n' \
                "$app" "$img_url" "$app" "$site_url"
        else
            printf '![screenshot of %s](%s)\n\n' "$app" "$img_url"
        fi
        cat <<'EOF'
**Checklist**
- [ ] review the screenshot(s) above
- [ ] add the best one to the _SCREENSHOTS_ line for this app in the catalog
- [ ] close this issue when done

_Reproduction (AppImage/AppMan):_
```
appman -i --user <app>
```
EOF
    } > "$WORK_DIR/$app.body.md"

    if gh issue create -R "$REPO" --title "Screenshot for $app" \
        --body-file "$WORK_DIR/$app.body.md" >"$WORK_DIR/$app.issue.log" 2>&1; then
        result_line=$(tail -n1 "$WORK_DIR/$app.issue.log")
        log "issue created: $result_line"
        results+=("OK $app")
    else
        log "issue creation failed: $(tail -n3 "$WORK_DIR/$app.issue.log")"
        results+=("FAIL $app (issue)")
    fi
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