#!/usr/bin/env bash
# S3 tests: Share-to-Termux handlers, Tasker scripts, tasker_setup.sh. Temp dirs + fake HOME only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; H="$T/home"; mkdir -p "$S" "$H/downloads" "$T/media/DCIM/TikTok" "$T/fakebin" "$T/bin"
for f in normalize.sh worker.sh qctl.py download.sh scan_lib.sh q.sh shortcuts.sh master_run.sh move_assets.sh share_handler.sh tasker_setup.sh config_lib.sh webui.py webui.html; do cp "$HERE/$f" "$S/"; done
export HOME="$H" MEDIA_DIR="$T/media" TMPDIR="$T" PATH="$T/fakebin:$PATH" WEBUI_PORT=$((20000 + RANDOM % 20000))
OUT="$MEDIA_DIR/Movies/NormalizedVideo"; LOGF="$S/media_processor_log.txt"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
stat_() { python3 "$S/qctl.py" stats; }
waitfor() { local i; for i in $(seq 1 "${2:-80}"); do eval "$1" && return 0; sleep 0.5; done; return 1; }

ffmpeg -v error -y -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i "sine=frequency=440:duration=3,volume=-28dB" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/good.mp4"
cat > "$T/fakebin/yt-dlp" <<Y
#!/usr/bin/env bash
[[ "\${1:-}" == "-U" ]] && exit 0
dir=""; res=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -P) dir="\$2"; shift 2;; --print-to-file) res="\$3"; shift 3;; -o|-S) shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
echo "url=\$url" >> "$T/fake.log"
id=\$(basename "\$url" | tr -cd 'A-Za-z0-9'); mkdir -p "\$dir"; f="\$dir/T \$id [\$id].mp4"; cp "$T/good.mp4" "\$f"; [[ -n "\$res" ]] && echo "\$f" >> "\$res"
Y
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/termux-media-scan"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/toasts.log"\n' "$T" > "$T/fakebin/termux-toast"
chmod +x "$T/fakebin/"*
reset() { pkill -f "$S/worker.sh" 2>/dev/null; sleep 0.3; rm -rf "$S/data" "$MEDIA_DIR/Movies" "$MEDIA_DIR/Pictures" "$MEDIA_DIR/DCIM/TikTok/"* "$H/downloads/"* "$T/toasts.log" "$T/fake.log" "$T/scan.log"; : > "$LOGF"; }

echo "== S1 shortcuts.sh installs the share handlers + Tasker scripts"
printf '#!/bin/sh\necho my-old-opener\n' > /dev/null; mkdir -p "$H/bin"; printf '#!/bin/sh\necho my-old-opener\n' > "$H/bin/termux-url-opener"
BIN_DIR="$T/bin" bash "$S/shortcuts.sh" > "$T/sc.out" 2>&1
chk "termux-url-opener and termux-file-editor installed, executable" "[[ -x '$H/bin/termux-url-opener' && -x '$H/bin/termux-file-editor' ]]"
chk "your own old termux-url-opener was kept as a .bak file, not destroyed" "ls '$H/bin/' | grep -q '^termux-url-opener.bak.' && grep -q my-old-opener '$H/bin/'termux-url-opener.bak.*"
chk "3 Tasker scripts installed (700)" "[[ \$(ls '$H/.termux/tasker/' | wc -l) == 3 && \$(stat -c %a '$H/.termux/tasker/media-queue-run.sh') == 700 ]]"
bak1=$(ls "$H/bin" | grep -c bak); BIN_DIR="$T/bin" bash "$S/shortcuts.sh" >/dev/null 2>&1
chk "second run: idempotent, no extra backups" "[[ \$(ls '$H/bin' | grep -c bak) == $bak1 ]]"
chk "handler content points at this folder" "grep -q '$S/share_handler.sh' '$H/bin/termux-url-opener'"

echo "== S2 shared TikTok-style text (a link inside words) via termux-url-opener"
reset; start=$(date +%s.%N)
"$H/bin/termux-url-opener" "Check out this video! https://vm.tiktok.com/ZSabc123/ #fyp #cool" > "$T/s2.out" 2>&1; rc=$?
el=$(awk -v a="$start" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
chk "returns at once (${el}s < 3s), exit 0" "[[ $rc == 0 ]] && awk -v e=$el 'BEGIN{exit !(e<3)}'"
chk "job processed by the background worker" "waitfor '[[ \$(stat_) == \"pending=0 running=0 done=1 failed=0\" ]]'"
chk "downloaded link was the clean URL, not the hashtags" "grep -q 'url=https://vm.tiktok.com/ZSabc123/\$' '$T/fake.log'"
chk "1 output in NormalizedVideo" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 1 ]]"
chk "toast shown" "grep -q Queued '$T/toasts.log'"
"$H/bin/termux-url-opener" "again https://vm.tiktok.com/ZSabc123/" > "$T/s2b.out" 2>&1; rc=$?
chk "sharing the same link again: duplicate message, exit 1, nothing queued" "[[ $rc == 1 ]] && grep -qi duplicate '$T/s2b.out' && [[ \$(grep -c url= '$T/fake.log') == 1 ]]"
"$H/bin/termux-url-opener" "no link here" > "$T/s2c.out" 2>&1; rc=$?
chk "text without a link: clear message, exit 1" "[[ $rc == 1 ]] && grep -q 'No link' '$T/s2c.out'"

echo "== S3 shared video file (Termux copy in ~/downloads) via termux-file-editor"
reset; cp "$T/good.mp4" "$H/downloads/my holiday.mp4"
"$H/bin/termux-file-editor" "$H/downloads/my holiday.mp4" > "$T/s3.out" 2>&1; rc=$?
chk "exit 0" "[[ $rc == 0 ]]"
chk "processed; the Termux COPY is deleted after the verified output" "waitfor '[[ \$(ls \"$OUT\"/*.mp4 2>/dev/null | wc -l) == 1 && ! -e \"$H/downloads/my holiday.mp4\" ]]'"
reset; mkdir -p "$T/media/Movies2"; cp "$T/good.mp4" "$T/media/Movies2/real original.mp4"
"$H/bin/termux-file-editor" "$T/media/Movies2/real original.mp4" > /dev/null 2>&1
chk "a file outside ~/downloads is the user's real file: processed but KEPT" "waitfor '[[ \$(ls \"$OUT\"/*.mp4 2>/dev/null | wc -l) == 1 ]]' && [[ -f '$T/media/Movies2/real original.mp4' ]]"

echo "== S4 shared text saved by Termux as .txt (link inside words)"
reset; printf 'Look at this: https://example.com/watch/xyz9 amazing\n' > "$H/downloads/shared.txt"
"$H/bin/termux-file-editor" "$H/downloads/shared.txt" > /dev/null 2>&1; rc=$?
chk "link queued from the .txt, exit 0" "[[ $rc == 0 ]] && waitfor '[[ \$(stat_) == \"pending=0 running=0 done=1 failed=0\" ]]' && grep -q 'url=https://example.com/watch/xyz9' '$T/fake.log'"
chk ".txt copy removed" "[[ ! -e '$H/downloads/shared.txt' ]]"
printf 'just words, no link\n' > "$H/downloads/plain.txt"
"$H/bin/termux-file-editor" "$H/downloads/plain.txt" > "$T/s4b.out" 2>&1; rc=$?
chk ".txt without a link: message, exit 1, file left alone" "[[ $rc == 1 && -f '$H/downloads/plain.txt' ]] && grep -q 'No link' '$T/s4b.out'"

echo "== S5 mixed / bad input"
reset; cp "$T/good.mp4" "$H/downloads/a.mp4"; cp "$T/good.mp4" "$H/downloads/b.mkv"; echo x > "$H/downloads/doc.pdf"; echo "not video" > "$H/downloads/broken.mp4"
"$H/bin/termux-file-editor" "$H/downloads/a.mp4" "$H/downloads/doc.pdf" "$H/downloads/b.mkv" "$H/downloads/missing.mp4" "$H/downloads/broken.mp4" > "$T/s5.out" 2>&1; rc=$?
chk "exit 0 (something was queued)" "[[ $rc == 0 ]]"
chk "pdf and missing file reported, pdf untouched" "grep -q 'Not a video' '$T/s5.out' && grep -q 'not found' '$T/s5.out' && [[ -f '$H/downloads/doc.pdf' ]]"
chk "3 video jobs finish: 2 done, broken one failed" "waitfor '[[ \$(stat_) == \"pending=0 running=0 done=2 failed=1\" ]]'"
chk "broken copy is KEPT (nothing deleted unless verified)" "[[ -f '$H/downloads/broken.mp4' && ! -e '$H/downloads/a.mp4' && ! -e '$H/downloads/b.mkv' ]]"
"$H/bin/termux-file-editor" > /dev/null 2>&1; chk "no arguments -> exit 1" "[[ $? == 1 ]]"
bash "$S/share_handler.sh" nonsense >/dev/null 2>&1; chk "bad mode -> exit 2" "[[ $? == 2 ]]"

echo "== S6 Tasker scripts (run with a bare environment, as Termux:Tasker would)"
reset; cp "$T/good.mp4" "$MEDIA_DIR/DCIM/TikTok/user_2026-10-01_7697297583915486400.mp4"; touch -d '1 minute ago' "$MEDIA_DIR/DCIM/TikTok/"*
env -i HOME="$H" PATH="$PATH" MEDIA_DIR="$MEDIA_DIR" TMPDIR="$T" bash "$H/.termux/tasker/media-queue-run.sh" > "$T/s6.out" 2>&1; rc=$?
chk "queue-run = the tiktok flow: folder video processed" "[[ $rc == 0 && \$(ls '$OUT'/*.mp4 | wc -l) == 1 ]]"
env -i HOME="$H" PATH="$PATH" MEDIA_DIR="$MEDIA_DIR" TMPDIR="$T" WEBUI_PORT="$WEBUI_PORT" bash "$H/.termux/tasker/media-queue-ui.sh" > "$T/s6b.out" 2>&1
chk "queue-ui starts the web page" "bash '$S/q.sh' ui status | grep -q running && curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$WEBUI_PORT/ | grep -q 200"
bash "$S/q.sh" ui stop >/dev/null
env -i HOME="$H" PATH="$PATH" MEDIA_DIR="$MEDIA_DIR" TMPDIR="$T" bash "$H/.termux/tasker/media-queue-stop.sh" > "$T/s6c.out" 2>&1
chk "queue-stop answers (no worker running)" "grep -q 'no worker' '$T/s6c.out'"

echo "== S7 tasker_setup.sh edits only one setting, safely"
P="$H/.termux/termux.properties"; printf '# my settings\nextra-keys = [["ESC","TAB"]]\n# allow-external-apps = true\nbell-character = ignore\n' > "$P"
bash "$S/tasker_setup.sh" > "$T/ts.out" 2>&1
chk "setting enabled once, other lines untouched" "[[ \$(grep -c '^allow-external-apps = true' '$P') == 1 ]] && grep -q 'extra-keys' '$P' && grep -q 'bell-character = ignore' '$P' && grep -q '# my settings' '$P'"
chk "commented-out old line replaced, not duplicated" "[[ \$(grep -c 'allow-external-apps' '$P') == 1 ]]"
bash "$S/tasker_setup.sh" > "$T/ts2.out" 2>&1; chk "second run: already true" "grep -q 'already true' '$T/ts2.out' && [[ \$(grep -c 'allow-external-apps' '$P') == 1 ]]"
printf 'allow-external-apps = false\n' > "$P"; bash "$S/tasker_setup.sh" >/dev/null 2>&1; chk "false -> true" "grep -q '^allow-external-apps = true' '$P' && ! grep -q false '$P'"
bash "$S/tasker_setup.sh" --undo >/dev/null 2>&1; chk "--undo removes it" "! grep -q allow-external-apps '$P'"
chk "setup prints the Tasker steps" "grep -q 'Set up Quick Setting Tile' '$T/ts.out'"

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
