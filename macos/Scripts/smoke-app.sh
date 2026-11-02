#!/bin/bash
# Smoke test for the packaged app (run ./bundle.sh first): ./Scripts/smoke-app.sh [path/to/Skillcask.app]
#
# 1. `Contents/MacOS/Skillcask --version` must exit 64 within 2 s (the CLI-style refusal, before any window).
# 2. Fixture start (SKILLCASK_UI_FIXTURES=1): reads its resources through `Bundle.module` at launch, so it
#    must still be alive after a few seconds with exactly one on-screen window: the resource bundle
#    resolves inside the .app. It runs no CLI, so it is also the control for the access-time signal below
#    (it runs first: the system's scan of a freshly built bundle on first launch reads the helper too).
#    2b. The same start over a saved column layout whose columns overlap: the app drops it before the window
#    opens and shows one window.
# 3. Live start with a fresh SKILLCASK_HOME and a PATH without skillcask, so the bundled
#    `Contents/Helpers/skillcask` is the only CLI it can use. For ~10 s the process started here stays
#    alive, no other new process of this bundle's executable appears, and its children stay few. The
#    positive proof that the bundled CLI was accepted is exactly ONE on-screen window: the main window
#    without the CLI onboarding sheet (a sheet is a window of its own) and without a duplicate. The
#    helper's access time moving past the launch is a secondary signal (its `--version` probe takes
#    milliseconds, shorter than a `ps` sample, and another copy of the app may run the same helper).
#
# Only the PIDs started here are ever signalled (no name-based kills); a copy of the app the user already
# runs from the same bundle is left alone and not counted. The app's defaults domain is exported first and
# imported back afterwards (or deleted when it did not exist), so the user's settings come back as they
# were. Needs a logged-in GUI session (the window checks use the window server). Exits non-zero on any
# failure.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:-.build/Skillcask.app}
app=$(cd "$app" && pwd -P)
exe=$app/Contents/MacOS/Skillcask
helper=$app/Contents/Helpers/skillcask
domain=io.github.puniserv.skillcask
clean_path=/usr/bin:/bin:/usr/sbin:/sbin
[ -x "$exe" ] || { echo "smoke: no executable at $exe (run ./bundle.sh)" >&2; exit 1; }
[ -x "$helper" ] || { echo "smoke: no helper at $helper" >&2; exit 1; }

tmp=$(mktemp -d -t skillcask-smoke)
pid=
had_domain=0
if defaults domains | tr ',' '\n' | sed 's/^ *//' | grep -qx "$domain"; then
    had_domain=1
    defaults export "$domain" "$tmp/defaults.plist"
fi
# Step 2b makes the app discard its saved window state and the launches write a new one: the user's is kept aside and
# put back afterwards; when there was none, the one the run wrote is removed.
saved_state="$HOME/Library/Saved Application State/$domain.savedState"
had_saved_state=0
if [ -e "$saved_state" ] || [ -L "$saved_state" ]; then
    had_saved_state=1
    ditto "$saved_state" "$tmp/saved-state"
fi
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}
ok() { echo "ok: $*"; }

# Sends TERM to the recorded PID only, then KILL after 5 s, and reaps it.
stop() {
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    pid=
}

cleanup() {
    stop
    if [ "$had_domain" = 1 ]; then
        defaults delete "$domain" >/dev/null 2>&1 || true
        defaults import "$domain" "$tmp/defaults.plist" || echo "smoke: could not restore $domain" >&2
    else
        defaults delete "$domain" >/dev/null 2>&1 || true
    fi
    if [ "$had_saved_state" = 1 ]; then
        rm -rf "$saved_state"
        ditto "$tmp/saved-state" "$saved_state" || echo "smoke: could not restore $saved_state" >&2
    else
        rm -rf "$saved_state"
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

# Number of on-screen, layer-0 (normal) windows owned by PID $1; owner PIDs need no screen-recording
# permission.
cat > "$tmp/windows.js" <<'EOF'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = parseInt(argv[0], 10);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0));
  let n = 0;
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i);
    if (w.objectForKey('kCGWindowOwnerPID').js === pid && w.objectForKey('kCGWindowLayer').js === 0 &&
        w.objectForKey('kCGWindowIsOnscreen').js === true) n++;
  }
  return String(n);
}
EOF
windows() { osascript -l JavaScript "$tmp/windows.js" "$1" 2>/dev/null || echo "?"; }

# Starts the app with a clean environment plus "$@" (extra NAME=value pairs), recording its PID.
# `-appUpdates.consent declined` (argument domain, D51): no consent card and no automatic update check, so a smoke
# run never asks GitHub.
launch() {
    env -i HOME="$HOME" USER="${USER:-}" TMPDIR="$tmp" LANG="${LANG:-en_US.UTF-8}" \
        PATH="$clean_path" SKILLCASK_HOME="$tmp/home" "$@" \
        "$exe" -binaryPath "" -appUpdates.consent declined -ApplePersistenceIgnoreState YES >"$tmp/app.log" 2>&1 &
    pid=$!
}

# PIDs running this bundle's executable, by full path, from a `ps -o pid=,ppid=,command=` snapshot on stdin.
pids_of_exe() {
    awk -v exe="$exe" '{ p = $1; $1 = ""; $2 = ""; sub(/^  /, "");
        if ($0 == exe || index($0, exe " ") == 1) print p }'
}

echo "app: $app"
echo "gui: $(lipo -archs "$exe")  helper: $(lipo -archs "$helper")  $("$helper" --version)"

# --- 1. CLI-style start is refused ---------------------------------------------------------------
"$exe" --version >"$tmp/version.out" 2>"$tmp/version.err" &
pid=$!
start=$(date +%s)
for _ in $(seq 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then
    fail "Skillcask --version still running after 2 s"
    stop
else
    status=0
    wait "$pid" || status=$?
    pid=
    if [ "$status" = 64 ]; then
        ok "Skillcask --version exited 64 in $(($(date +%s) - start)) s: $(cat "$tmp/version.err")"
    else
        fail "Skillcask --version exited $status, want 64 (stderr: $(cat "$tmp/version.err"))"
    fi
fi

# --- 2. Fixture start: Bundle.module resolves in the .app; the control for the access-time signal -----
touch -a -t 200001010000 "$helper"
control_start=$(date +%s)
launch SKILLCASK_UI_FIXTURES=1
sleep 4
if kill -0 "$pid" 2>/dev/null; then
    win=$(windows "$pid")
    if [ "$win" = 1 ]; then
        ok "fixture mode (reads Bundle.module at launch) alive after 4 s with 1 on-screen window"
    else
        fail "fixture mode is alive but shows $win on-screen windows, want 1"
    fi
    if [ "$(stat -f %a "$helper")" -ge "$control_start" ]; then
        control_moved=1
        echo "note: the helper's access time moved without a CLI run (first-launch scan or another copy of the app)"
    else
        control_moved=0
        ok "control: launching without a CLI leaves the helper's access time alone"
    fi
else
    status=0
    wait "$pid" || status=$?
    pid=
    fail "fixture mode exited $status; log: $(cat "$tmp/app.log")"
    control_moved=1
fi
stop

# --- 2b. An overlapping saved column layout is dropped before the window opens (`SplitViewFrames`) -------
# The layout from a report, as AppKit saves a sidebar collapsed at quit (the list at x 0 under it): on macOS 26 it
# opened the window empty and hung it on a sidebar toggle. Fixture mode runs the same entry point and needs no CLI.
layout_key="NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
defaults write "$domain" "$layout_key" -array \
    "0.000000, 0.000000, 228.000000, 1852.000000, NO, NO" \
    "0.000000, 0.000000, 613.000000, 1852.000000, NO, NO" \
    "614.000000, 0.000000, 784.000000, 1852.000000, NO, NO"
launch SKILLCASK_UI_FIXTURES=1
sleep 4
if kill -0 "$pid" 2>/dev/null; then
    win=$(windows "$pid")
    layout=$(defaults read "$domain" "$layout_key" 2>/dev/null | tr -d '\n' || true)
    if [ "$win" != 1 ]; then
        fail "with an overlapping saved layout the app shows $win on-screen windows, want 1"
    elif printf '%s' "$layout" | grep -Eq ', 613(\.0+)?, '; then
        # The list kept the saved width: the layout was restored (AppKit may move the columns apart itself).
        fail "the overlapping saved layout was restored: $layout"
    elif [ -n "$layout" ] && ! printf '%s' "$layout" | grep -Eq '"0(\.0+)?, 0(\.0+)?, 220(\.0+)?, '; then
        # Dropped, the key is gone or saved again with the sidebar at its ideal 220.
        fail "the saved layout is neither gone nor laid out from the ideal widths: $layout"
    else
        ok "an overlapping saved layout is dropped; 1 on-screen window${layout:+, layout now: $layout}"
    fi
else
    status=0
    wait "$pid" || status=$?
    pid=
    fail "with an overlapping saved layout the app exited $status; log: $(cat "$tmp/app.log")"
fi
stop
defaults delete "$domain" "$layout_key" >/dev/null 2>&1 || true

# --- 3. Live start: one process, one window, the bundled helper ------------------------------------
mkdir -p "$tmp/home"
if PATH=$clean_path command -v skillcask >/dev/null 2>&1; then
    fail "the clean PATH $clean_path has a skillcask"
fi
# Copies of this bundle that were already running (e.g. the user's) are not ours to count.
baseline=$(ps -axww -o pid=,ppid=,command= | pids_of_exe | sort)
[ -z "$baseline" ] || echo "note: already running from this bundle, ignored: $(echo $baseline)"
touch -a -t 200001010000 "$helper"
launched=$(date +%s)
launch
echo "started $exe (pid $pid), SKILLCASK_HOME=$tmp/home, PATH=$clean_path"

samples=0
max_children=0
helper_seen=
deadline=$((launched + 10))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        status=0
        wait "$pid" || status=$?
        fail "the app (pid $pid) exited with status $status during sampling, sample $samples; log: $(cat "$tmp/app.log")"
        pid=
        break
    fi
    snapshot=$(ps -axww -o pid=,ppid=,command=)
    samples=$((samples + 1))
    # New processes running THIS bundle's executable (by full path, minus the baseline): only ours.
    mine=$(printf '%s\n' "$snapshot" | pids_of_exe | sort | comm -23 - <(printf '%s\n' "$baseline" | grep . || true))
    if [ "$mine" != "$pid" ]; then
        fail "sample $samples: new processes of $exe are [$(echo $mine)], want exactly [$pid]"
        break
    fi
    children=$(printf '%s\n' "$snapshot" | awk -v p="$pid" '$2 == p' | grep -c . || true)
    [ "$children" -gt "$max_children" ] && max_children=$children
    if [ "$children" -gt 8 ]; then
        fail "sample $samples: the app has $children children"
        break
    fi
    seen=$(printf '%s\n' "$snapshot" | grep -F "$helper" | grep -v grep | head -n 1 || true)
    [ -n "$seen" ] && [ -z "$helper_seen" ] && helper_seen=$seen
    sleep 0.05
done
win=0; [ -z "$pid" ] || win=$(windows "$pid")
accessed=$(stat -f %a "$helper")
if [ "$failures" = 0 ]; then
    ok "$samples samples over 10 s: exactly one new process of this bundle (pid $pid), at most $max_children children"
fi
# The positive proof: one window means the main window without the onboarding sheet the app shows when
# it finds no usable CLI, and the bundled helper is the only CLI it could find.
if [ "$win" = 1 ]; then
    ok "the app shows exactly 1 on-screen window (main window, no CLI onboarding sheet)"
else
    fail "the app (pid $pid) shows $win on-screen windows, want 1 (2: the onboarding sheet; 0: no GUI session?)"
fi
# Secondary signals only.
if [ -n "$helper_seen" ]; then
    echo "note: helper seen in ps: $helper_seen"
elif [ "$accessed" -ge "$launched" ]; then
    echo "note: the helper's access time $(date -r "$accessed" +%T) is after the launch at $(date -r "$launched" +%T)" \
        "(control moved: $control_moved)"
else
    echo "note: no secondary sign that the helper ran (not in ps, access time $(date -r "$accessed"))"
fi
stop
[ -s "$tmp/app.log" ] && echo "app stderr: $(cat "$tmp/app.log")"

if [ "$failures" -gt 0 ]; then
    echo "smoke: $failures failure(s)"
    exit 1
fi
echo "smoke: all checks passed"
