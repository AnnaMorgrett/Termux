#!/usr/bin/env bash
# S1c tests: q.sh, shortcuts.sh, master_run.sh (tiktok flow) on the queue. Temp dir only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S" "$T/media/DCIM/TikTok" "$T/media/Download/yt-dlp" "$T/fakebin" "$T/bin" "$T/tmp"
for f in normalize.sh worker.sh qctl.py download.sh scan_lib.sh q.sh shortcuts.sh master_run.sh move_assets.sh install.sh; do cp "$HERE/$f" "$S/"; done
export MEDIA_DIR="$T/media" QUEUE_DIR="$S/data/queue" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" HOME="$T/home"   # fake HOME: shortcuts.sh must never touch the real ~/bin
mkdir -p "$T/home"
Q="bash $S/q.sh"; OUT="$MEDIA_DIR/Movies/NormalizedVideo"; LOGF="$S/media_processor_log.txt"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
stat_() { python3 "$S/qctl.py" stats; }
waitfor() { local i; for i in $(seq 1 "${2:-60}"); do eval "$1" && return 0; sleep 0.5; done; return 1; }

ffmpeg -v error -y -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i "sine=frequency=440:duration=3,volume=-28dB" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/good.mp4"
cat > "$T/fakebin/yt-dlp" <<Y
#!/usr/bin/env bash
[[ "\${1:-}" == "-U" ]] && exit 0
dir=""; res=""; url=""; extra=""
while [[ \$# -gt 0 ]]; do case "\$1" in -P) dir="\$2"; shift 2;; --print-to-file) res="\$3"; shift 3;; -o|-S) shift 2;; --no-mtime) shift;; -*) extra+="\$1 "; shift;; *) url="\$1"; shift;; esac; done
echo "run url=\$url extra=\$extra" >> "$T/fake.log"
if [[ -f "$T/SLOWONCE" ]]; then rm -f "$T/SLOWONCE"; sleep 4; fi
[[ "\$url" == *bad* ]] && exit 1
id=\$(basename "\$url" | tr -cd 'A-Za-z0-9'); mkdir -p "\$dir"
f="\$dir/Title \$id [\$id].mp4"; cp "$T/good.mp4" "\$f"; [[ -n "\$res" ]] && echo "\$f" >> "\$res"
Y
cat > "$T/fakebin/termux-media-scan" <<Y
#!/usr/bin/env bash
echo "scan \$#" >> "$T/scan.log"; for a in "\$@"; do echo "  \$a" >> "$T/scan.log"; done
Y
chmod +x "$T/fakebin/"*
reset() { pkill -f "$S/worker.sh" 2>/dev/null; sleep 0.3; rm -rf "$S/data" "$MEDIA_DIR/Movies" "$MEDIA_DIR/Pictures" "$MEDIA_DIR/DCIM/TikTok/"* "$MEDIA_DIR/Download/yt-dlp/"* "$T/scan.log" "$T/fake.log" "$T/SLOWONCE" "$T/tmp/"*; : > "$LOGF"; }

echo "== C1 q add: links + local file + duplicate + relative path, background worker"
reset; cp "$T/good.mp4" "$T/my clip.mp4"
( cd "$T" && $Q add "https://s.com/v1" "my clip.mp4" "https://s.com/v1" "Look at this https://s.com/v2 wow" ) > "$T/c1.out" 2>&1; rc=$?
chk "add returns at once, exit 0" "[[ $rc == 0 ]]"
chk "duplicate reported" "grep -q duplicate '$T/c1.out'"
chk "background worker finishes all 3 jobs" "waitfor '[[ \$(stat_) == \"pending=0 running=0 done=3 failed=0\" ]]'"
chk "3 outputs; local file kept" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 3 && -f '$T/my clip.mp4' ]]"
chk "link inside shared text was found (v2)" "grep -q 'url=https://s.com/v2' '$T/fake.log'"
chk "ONE media scan with 3 files" "waitfor '[[ \$(grep -c ^scan \"$T/scan.log\") == 1 ]]' 10 && head -1 '$T/scan.log' | grep -q 'scan 3'"
chk "q stats shows idle worker" "waitfor '$Q stats | grep -q worker=idle' 10"

echo "== C2 dl with extra yt-dlp options (foreground)"
reset
$Q dl "https://s.com/v9" -f bestvideo+bestaudio > "$T/c2.out" 2>&1; rc=$?
chk "exit 0, output made" "[[ $rc == 0 && \$(ls '$OUT'/*.mp4 | wc -l) == 1 ]]"
chk "extra options reached yt-dlp" "grep -q 'url=https://s.com/v9 extra=-f ' '$T/fake.log'"
$Q dl "https://s.com/v9" > "$T/c2b.out" 2>&1
chk "same link again -> duplicate, no second download" "grep -q duplicate '$T/c2b.out' && [[ \$(grep -c 'v9' '$T/fake.log') == 1 ]]"
$Q dl > /dev/null 2>&1; chk "dl without URL -> exit 1" "[[ $? == 1 ]]"

echo "== C3 add while a worker is busy -> same worker handles it"
reset; touch "$T/SLOWONCE"
$Q add "https://s.com/a1" > /dev/null; sleep 1.5; $Q add "https://s.com/a2" > "$T/c3.out" 2>&1
chk "both done" "waitfor '[[ \$(stat_) == \"pending=0 running=0 done=2 failed=0\" ]]' 40"
chk "never two workers at once (log shows no overlapping starts)" "! grep -q 'Stale worker lock' '$LOGF'"

echo "== C4 tiktok flow (master_run.sh): folders -> queue -> worker, one scan, images moved"
reset
for n in a b; do cp "$T/good.mp4" "$MEDIA_DIR/DCIM/TikTok/user_2026-10-01_76972975839154864$n.mp4"; done
cp "$T/good.mp4" "$MEDIA_DIR/Download/yt-dlp/Some Title [abc123].mp4"
echo "not a video" > "$MEDIA_DIR/DCIM/TikTok/broken.mp4"
ffmpeg -v error -y -f lavfi -i color=c=red:s=64x64:d=1 -frames:v 1 "$MEDIA_DIR/DCIM/TikTok/pic.jpg"
touch -d '1 minute ago' "$MEDIA_DIR/DCIM/TikTok/"* "$MEDIA_DIR/Download/yt-dlp/"*
bash "$S/master_run.sh" > "$T/c4.out" 2>&1; rc=$?
chk "master_run exit 0" "[[ $rc == 0 ]]"
chk "3 videos normalized, originals consumed" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 3 && ! -e '$MEDIA_DIR/DCIM/TikTok/user_2026-10-01_76972975839154864a.mp4' && -z \$(ls '$MEDIA_DIR/Download/yt-dlp') ]]"
chk "broken file kept, failure recorded" "[[ -f '$MEDIA_DIR/DCIM/TikTok/broken.mp4' ]] && python3 '$S/qctl.py' list --status failed | grep -q 'no video stream'"
chk "image relocated out of TikTok folder" "[[ ! -e '$MEDIA_DIR/DCIM/TikTok/pic.jpg' && -n \$(ls '$MEDIA_DIR/Pictures/TikTok_Assets') ]]"
chk "exactly ONE media scan covering videos + image (4 files)" "[[ \$(grep -c ^scan '$T/scan.log') == 1 ]] && head -1 '$T/scan.log' | grep -q 'scan 4'"
bash "$S/master_run.sh" > "$T/c4b.out" 2>&1
chk "second run: broken file retried (not duplicated), still 1 failed job" "[[ \$(python3 '$S/qctl.py' list --status failed | wc -l) == 1 ]]"
chk "second run created no extra outputs" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 3 ]]"

echo "== C5 queue commands"
reset; python3 "$S/qctl.py" add --url "https://s.com/x1" >/dev/null; python3 "$S/qctl.py" add --url "https://s.com/x2" >/dev/null
python3 "$S/qctl.py" next >/dev/null; python3 "$S/qctl.py" fail 1 "oops"
chk "q list failed" "$Q list failed | grep -q oops"
chk "q remove running refused / pending ok" "$Q remove 2 >/dev/null && ! $Q list | grep -q x2"
Q_NO_BG=1 $Q retry all >/dev/null; chk "q retry all" "[[ \$(stat_) == 'pending=1 running=0 done=0 failed=0' ]]"
python3 "$S/qctl.py" next >/dev/null; python3 "$S/qctl.py" done 1; $Q clear done >/dev/null; chk "q clear done" "[[ \$(stat_) == 'pending=0 running=0 done=0 failed=0' ]]"
chk "q stop with no worker says so" "$Q stop | grep -q 'no worker'"
chk "q unknown command -> exit 2" "$Q nonsense >/dev/null 2>&1; [[ \$? == 2 ]]"

echo "== C6 shortcuts.sh creates dl / tiktok / q that work from any folder"
reset; BIN_DIR="$T/bin" bash "$S/shortcuts.sh" > /dev/null
chk "3 commands created and executable" "[[ -x '$T/bin/dl' && -x '$T/bin/tiktok' && -x '$T/bin/q' ]]"
chk "q wrapper works from another folder" "( cd / && '$T/bin/q' stats ) | grep -q 'pending=0'"
chk "dl wrapper downloads+normalizes" "( cd / && '$T/bin/dl' 'https://s.com/w1' >/dev/null 2>&1 ); [[ \$(ls '$OUT'/*.mp4 | wc -l) == 1 ]]"
chk "running shortcuts.sh twice is fine" "BIN_DIR='$T/bin' bash '$S/shortcuts.sh' >/dev/null"

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
