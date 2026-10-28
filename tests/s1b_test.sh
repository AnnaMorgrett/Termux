#!/usr/bin/env bash
# S1b tests: qctl.py queue + worker.sh. Uses a temp dir only (no real media touched).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S" "$T/media" "$T/fakebin"
for f in normalize.sh worker.sh qctl.py download.sh scan_lib.sh; do cp "$HERE/$f" "$S/"; done
export MEDIA_DIR="$T/media" QUEUE_DIR="$S/data/queue" PATH="$T/fakebin:$PATH"
Q="python3 $S/qctl.py"; OUT="$MEDIA_DIR/Movies/NormalizedVideo"; LOGF="$S/media_processor_log.txt"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

# prepared source video (quiet audio, h264)
ffmpeg -v error -y -f lavfi -i testsrc=size=320x240:rate=25:duration=3 -f lavfi -i "sine=frequency=440:duration=3,volume=-28dB" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/good.mp4"

# fake yt-dlp: honours -P, --print-to-file; URL containing 'bad' fails; SLOWFLAG file => sleeps
cat > "$T/fakebin/yt-dlp" <<Y
#!/usr/bin/env bash
dir=""; res=""; url=""
while [[ \$# -gt 0 ]]; do case "\$1" in -P) dir="\$2"; shift 2;; --print-to-file) res="\$3"; shift 3;; -o|-S) shift 2;; --no-mtime) shift;; *) url="\$1"; shift;; esac; done
echo "start \$(date +%s.%N) \$url" >> "$T/fake.log"
[[ -f "$T/SLOWFLAG" ]] && sleep 30
[[ "\$url" == *bad* ]] && { echo "ERROR: Unsupported URL" >&2; echo "end \$(date +%s.%N) \$url" >> "$T/fake.log"; exit 1; }
id=\$(basename "\$url" | tr -cd 'A-Za-z0-9'); mkdir -p "\$dir"
f="\$dir/Title \$id [\$id].mp4"; cp "$T/good.mp4" "\$f"
[[ -n "\$res" ]] && echo "\$f" >> "\$res"
echo "end \$(date +%s.%N) \$url" >> "$T/fake.log"
Y
cat > "$T/fakebin/termux-media-scan" <<Y
#!/usr/bin/env bash
echo "scan \$#" >> "$T/scan.log"; for a in "\$@"; do echo "  \$a" >> "$T/scan.log"; done
Y
chmod +x "$T/fakebin/"*
reset() { rm -rf "$S/data" "$MEDIA_DIR/Movies" "$MEDIA_DIR/Download" "$T/scan.log" "$T/fake.log" "$T/SLOWFLAG"; : > "$LOGF"; }

echo "== Q1 add / dedupe / validation"
reset
$Q add --url "https://www.tiktok.com/@u/video/7697297583915486497?utm_source=x&is_from_webapp=1" >/dev/null; r1=$?
$Q add --url "https://tiktok.com/@u/video/7697297583915486497/" >/dev/null; r2=$?
$Q add --url "https://youtu.be/abcdefghijk?si=zzz" >/dev/null
$Q add --url "https://www.youtube.com/watch?v=abcdefghijk&feature=share" >/dev/null; r3=$?
$Q add --url "https://example.com/v?a=1&utm_campaign=q" >/dev/null; r4=$?
$Q add --url "https://example.com/v?a=1" >/dev/null; r5=$?
chk "first add ok (0), same TikTok video other form -> duplicate (3)" "[[ $r1 == 0 && $r2 == 3 ]]"
chk "youtu.be and youtube.com/watch same video -> duplicate" "[[ $r3 == 3 ]]"
chk "tracking params ignored for generic URLs" "[[ $r4 == 0 && $r5 == 3 ]]"
$Q add --url "ftp://x" >/dev/null 2>&1; chk "non-http URL rejected (2)" "[[ $? == 2 ]]"
$Q add --url "https://a.com/x y" >/dev/null 2>&1; chk "URL with space rejected (2)" "[[ $? == 2 ]]"
$Q add --file "relative.mp4" >/dev/null 2>&1; chk "relative path rejected (2)" "[[ $? == 2 ]]"
$Q add --file "$T/nope.mp4" >/dev/null 2>&1; chk "missing file rejected (2)" "[[ $? == 2 ]]"
chk "stats: 3 pending" "[[ \$($Q stats) == 'pending=3 running=0 done=0 failed=0' ]]"

echo "== Q2 FIFO, one running at a time, done/fail records, retry"
reset; for i in 1 2 3; do $Q add --url "https://e.com/v$i" >/dev/null; done
l1=$($Q next); chk "first next = job 1" "[[ \$(echo \"$l1\" | cut -f1) == 1 ]]"
$Q next >/dev/null; chk "no second job while one is running (exit 1)" "[[ $? == 1 ]]"
$Q done 1 --output /x/y.mp4; l2=$($Q next); chk "then job 2" "[[ \$(echo \"$l2\" | cut -f1) == 2 ]]"
$Q fail 2 "boom"; chk "failure recorded with message" "$Q list --status failed | grep -q 'boom'"
l3=$($Q next); chk "failed job does not block: job 3 next" "[[ \$(echo \"$l3\" | cut -f1) == 3 ]]"
$Q done 3
$Q add --url "https://e.com/v1" >/dev/null 2>&1; chk "re-adding a DONE url -> duplicate (3)" "[[ $? == 3 ]]"
$Q add --url "https://e.com/v2" >/dev/null; chk "re-adding a FAILED url requeues it" "[[ \$($Q stats) == 'pending=1 running=0 done=2 failed=0' ]]"
$Q fail 2 x 2>/dev/null; $Q retry --all >/dev/null; chk "retry --all requeues failed" "[[ \$($Q stats | grep -o 'pending=[0-9]') == 'pending=1' ]]"

echo "== Q3 crash recovery (running -> pending), poison job gives up"
reset; $Q add --url "https://e.com/p1" >/dev/null; $Q next >/dev/null
chk "job stuck running" "[[ \$($Q stats) == 'pending=0 running=1 done=0 failed=0' ]]"
$Q recover >/dev/null; chk "recover -> pending" "[[ \$($Q stats) == 'pending=1 running=0 done=0 failed=0' ]]"
for i in 1 2; do $Q next >/dev/null; $Q recover >/dev/null; done
chk "after 3 interrupted attempts it is failed, not looping" "$Q list --status failed | grep -q 'giving up'"

echo "== Q4 concurrency: parallel adds"
reset; for i in $(seq 1 25); do $Q add --url "https://e.com/par$i" >/dev/null & done; wait
chk "25 distinct parallel adds -> 25 jobs, unique ids" "[[ \$($Q list --json | python3 -c 'import sys,json;j=json.load(sys.stdin);print(len(j),len({x[\"id\"] for x in j}))') == '25 25' ]]"
reset; for i in $(seq 1 15); do $Q add --url "https://e.com/same" >/dev/null 2>&1 & done; wait
chk "15 parallel adds of the SAME url -> exactly 1 job" "[[ \$($Q stats) == 'pending=1 running=0 done=0 failed=0' ]]"

echo "== W1 worker end-to-end: 2 URLs + dup + 1 local file (kept) + 1 bad URL"
reset
cp "$T/good.mp4" "$T/shared clip.mp4"
$Q add --url "https://site.com/video1" >/dev/null
$Q add --url "https://site.com/bad/video" >/dev/null
$Q add --file "$T/shared clip.mp4" >/dev/null
$Q add --url "https://site.com/video2" >/dev/null
$Q add --url "https://site.com/video1" >/dev/null 2>&1
( cd "$S" && bash worker.sh > "$T/w.out" 2>&1 ); rc=$?
chk "worker exit 0" "[[ $rc == 0 ]]"
chk "3 outputs created" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 3 ]]"
chk "local shared file kept" "[[ -f '$T/shared clip.mp4' ]]"
chk "downloaded originals consumed (yt-dlp folder empty)" "[[ -z \$(ls '$MEDIA_DIR/Download/yt-dlp' 2>/dev/null) ]]"
chk "stats: done=3 failed=1" "[[ \$($Q stats) == 'pending=0 running=0 done=3 failed=1' ]]"
chk "failure recorded with reason" "$Q list --status failed | grep -q 'download failed'"
chk "bad job did not stop later jobs (video2 done after it)" "$Q list --status done | grep -q video2"
chk "ONE media scan call with 3 files" "[[ \$(grep -c '^scan' '$T/scan.log') == 1 && \$(head -1 '$T/scan.log') == 'scan 3' ]]"
chk "worker logged start/finish" "grep -q 'Worker finished: done=3 failed=1' '$LOGF'"
chk "no leftover lock/tmp files" "[[ ! -d '$S/data/queue/.worker.lock' && -z \$(ls -A '$S/data/queue' | grep -E '^\\.res|\\.tmp|scan.pending') ]]"
chk "yt-dlp calls never overlapped" "awk '/^start/{if(open)bad=1;open=1} /^end/{open=0} END{exit bad}' '$T/fake.log'"

echo "== W2 second worker while one runs; stop flag"
reset; touch "$T/SLOWFLAG"; $Q add --url "https://site.com/slow1" >/dev/null; $Q add --url "https://site.com/slow2" >/dev/null
( cd "$S" && bash worker.sh >/dev/null 2>&1 ) & W1=$!
sleep 3
( cd "$S" && bash worker.sh > "$T/w2.out" 2>&1 ); rc=$?
chk "second worker exits 0 saying already running" "[[ $rc == 0 ]] && grep -q 'already running' '$T/w2.out'"
touch "$S/data/queue/.stop"; rm -f "$T/SLOWFLAG"; pkill -f "fakebin/yt-dlp" 2>/dev/null; pkill -f 'sleep 30'; wait $W1 2>/dev/null
chk "stop flag honoured: not all jobs consumed" "[[ \$($Q stats | grep -o 'pending=[0-9]') != 'pending=0' || \$($Q stats | grep -o 'failed=[0-9]') != 'failed=0' ]]"
chk "stop flag removed" "[[ ! -f '$S/data/queue/.stop' ]]"

echo "== W3 resume after kill -9 (power loss simulation)"
reset; touch "$T/SLOWFLAG"; $Q add --url "https://site.com/resume1" >/dev/null; $Q add --url "https://site.com/resume2" >/dev/null
( cd "$S" && exec bash worker.sh >/dev/null 2>&1 ) & WP=$!
sleep 3
chk "job is running before the kill" "[[ \$($Q stats | grep -o 'running=[0-9]') == 'running=1' ]]"
kill -9 $WP; pkill -9 -f "fakebin/yt-dlp"; pkill -9 -f 'sleep 30'; sleep 1
chk "after kill -9: job still marked running, lock dir left behind" "[[ \$($Q stats | grep -o 'running=[0-9]') == 'running=1' && -d '$S/data/queue/.worker.lock' ]]"
rm -f "$T/SLOWFLAG"
( cd "$S" && bash worker.sh > "$T/w3.out" 2>&1 ); rc=$?
chk "new worker takes over stale lock, finishes both jobs" "[[ $rc == 0 && \$($Q stats) == 'pending=0 running=0 done=2 failed=0' ]]"
chk "outputs exist" "[[ \$(ls '$OUT'/*.mp4 | wc -l) == 2 ]]"
chk "recovery logged" "grep -q 'Stale worker lock' '$LOGF' && grep -q 'recovered=1' '$LOGF'"

echo "== W4 TERM: job goes back to pending, child stopped, lock released"
reset; touch "$T/SLOWFLAG"; $Q add --url "https://site.com/term1" >/dev/null
( cd "$S" && exec bash worker.sh >/dev/null 2>&1 ) & WP=$!
sleep 3; kill -TERM $WP; wait $WP 2>/dev/null; sleep 1
chk "job pending again (attempt not counted)" "[[ \$($Q stats) == 'pending=1 running=0 done=0 failed=0' && \$($Q list --json | grep -o '\"attempts\": [0-9]') == '\"attempts\": 0' ]]"
chk "lock released, no yt-dlp orphan" "[[ ! -d '$S/data/queue/.worker.lock' ]] && ! pgrep -f 'fakebin/yt-dlp' >/dev/null"
rm -f "$T/SLOWFLAG"

echo "== W5 empty queue"
reset; ( cd "$S" && bash worker.sh > "$T/w5.out" 2>&1 ); chk "empty queue: exit 0, done=0 failed=0" "[[ $? == 0 ]] && grep -q 'done=0 failed=0' '$T/w5.out'"

echo "== L1 lock works on storage WITHOUT flock (shared storage / FUSE)"
reset
chk "qctl no longer uses fcntl/flock at all" "! grep -qE '^import.*fcntl|fcntl\\.' '$S/qctl.py'"
cat > "$T/noflock.py" <<PYE
import fcntl, runpy, sys
def boom(*a, **k): raise OSError(38, "Function not implemented")   # what the phone's shared storage answers
fcntl.flock = boom; fcntl.lockf = boom
sys.argv = ["qctl.py"] + sys.argv[1:]
runpy.run_path("$S/qctl.py", run_name="__main__")
PYE
NQ="python3 $T/noflock.py"
$NQ add --url "https://e.com/nf1" >/dev/null 2>&1; r1=$?; $NQ add --url "https://e.com/nf2" >/dev/null 2>&1
chk "add/next/done work even when flock raises error 38" "[[ $r1 == 0 ]] && $NQ next >/dev/null && $NQ done 1 && [[ \$($NQ stats) == 'pending=1 running=0 done=1 failed=0' ]]"
chk "no lock directory left behind" "[[ ! -e '$S/data/queue/.lock.d' ]]"

echo "== L2 stale and busy locks"
reset; mkdir -p "$S/data/queue/.lock.d"; echo 999999 > "$S/data/queue/.lock.d/pid"
s0=$(date +%s); $Q add --url "https://e.com/st1" >/dev/null 2>&1; r=$?; el=$(( $(date +%s) - s0 ))
chk "lock left by a dead process is taken over at once (${el}s)" "[[ $r == 0 && $el -lt 3 ]]"
reset; mkdir -p "$S/data/queue/.lock.d"; touch -d '30 seconds ago' "$S/data/queue/.lock.d"
$Q add --url "https://e.com/st2" >/dev/null 2>&1; chk "abandoned lock (no pid file, old) is taken over" "[[ $? == 0 ]]"
reset; sleep 30 & HOLD=$!; mkdir -p "$S/data/queue/.lock.d"; echo $HOLD > "$S/data/queue/.lock.d/pid"
s0=$(date +%s); QUEUE_LOCK_TIMEOUT=2 $Q add --url "https://e.com/busy" > "$T/busy.out" 2>&1; r=$?; el=$(( $(date +%s) - s0 ))
chk "lock held by a LIVE process: waits, then exits 4 with a clear message (${el}s)" "[[ $r == 4 && $el -ge 2 && $el -le 6 ]] && grep -q 'queue is busy' '$T/busy.out'"
kill $HOLD 2>/dev/null
reset; python3 - <<PYE &
import os, sys, time
os.environ["QUEUE_DIR"] = "$S/data/queue"; sys.path.insert(0, "$S")
import qctl
with qctl.Locked():
    time.sleep(2)
PYE
sleep 0.7; s0=$(date +%s.%N); $Q add --url "https://e.com/wait" >/dev/null 2>&1; r=$?; el=$(awk -v a=$s0 -v b=$(date +%s.%N) 'BEGIN{printf "%.1f", b-a}'); wait
chk "a short-lived live holder: add waits for it, then succeeds (${el}s)" "[[ $r == 0 ]] && awk -v e=$el 'BEGIN{exit !(e>0.8)}'"

echo "== L3 built-in selftest"
reset; python3 "$S/qctl.py" selftest > "$T/st.out" 2>&1; chk "q selftest passes and cleans up" "grep -q 'SELFTEST PASS' '$T/st.out' && [[ -z \$(ls '$S/data' | grep selftest) ]]"

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
