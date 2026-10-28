#!/usr/bin/env bash
# tasker_setup.sh - ONE-TIME, optional: lets Tasker run the scripts in ~/.termux/tasker/.
# It sets  allow-external-apps = true  in ~/.termux/termux.properties (other lines untouched).
# Security: after this, an app that you ALSO grant Termux's "Run commands" permission can run
# commands in Termux. Undo any time:  bash tasker_setup.sh --undo
set -eu
P="${HOME:-/data/data/com.termux/files/home}/.termux/termux.properties"
mkdir -p "$(dirname "$P")"; touch "$P"
if [[ "${1:-}" == "--undo" ]]; then
    sed -i -E '/^[[:space:]]*allow-external-apps[[:space:]]*=/d' "$P"
    echo "allow-external-apps removed (default: off)"
elif grep -qE '^[[:space:]]*allow-external-apps[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$P"; then
    echo "allow-external-apps is already true"
else
    sed -i -E '/^[[:space:]]*#?[[:space:]]*allow-external-apps[[:space:]]*=/d' "$P"
    printf 'allow-external-apps = true\n' >> "$P"
    echo "allow-external-apps = true written"
fi
command -v termux-reload-settings &>/dev/null && termux-reload-settings || echo "(close and reopen Termux so it re-reads the setting)"
if [[ "${1:-}" != "--undo" ]]; then cat <<'T'

Next, in the Tasker app (Android needs you to do these taps once):
 1. Grant Tasker the permission "Run commands in Termux environment"
    (Android Settings > Apps > Tasker > Permissions > Additional permissions).
 2. Tasker > Tasks > + > name it "Queue run" > + (action) > Plugin > Termux:Tasker >
    Configuration (pencil) > Executable: media-queue-run.sh > save/back.
    Do the same for "Queue UI" (media-queue-ui.sh) and "Queue stop" (media-queue-stop.sh).
 3. New task "Setup tile": action Set up Quick Setting Tile > Tile 1 > Label "Media Queue" >
    short click Task = Queue run, long click Task = Queue UI, double click Task = Queue stop.
    Run "Setup tile" once (play button).
 4. Swipe down twice > pencil (edit) > drag the "Tasker" tile 1 into your active tiles.
T
fi
