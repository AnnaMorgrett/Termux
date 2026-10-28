#!/usr/bin/env bash
# S1d tests: the queue must work where flock does NOT (Android shared storage), survive dead/stale
# lock owners, and fail with ONE clear message (never a traceback, never touching files) when storage is broken.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
S="$T/scripts"; mkdir -p "$S" "$T/media/DCIM/TikTok" "$T/fakebin"
for f in qctl.py q.sh worker.sh normalize.sh download.sh scan_lib.sh master_run.sh move_assets.sh config_lib.sh; do cp "$HERE/$f" "$S/"; done
export MEDIA_DIR="$T/media" TMPDIR="$T" HOME="$T/home" PATH="$T/fakebin:$PATH" QUEUE_DIR="$S/data/queue"; mkdir -p "$HOME"
NOFC="$HERE/tests/nofcntl"
Q="python3 $S/qctl.py"
pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  PASS: $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/yt-dlp"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/fakebin/termux-media-scan"; chmod +x "$T/fakebin/"*
reset() { rm -rf "$S/data" "$T/media/DCIM/TikTok/"*; }

echo "== L1 qctl never uses file locks"
chk "importing qctl does not load fcntl" "python3 -c \"import sys; sys.path.insert(0,'$S'); import qctl; sys.exit('fcntl' in sys.modules)\""
chk "no fcntl.* call anywhere in qctl.py / webui.py" "! grep -nE 'fcntl\\.|import fcntl' '$S/qctl.py' '$HERE/webui.py' | grep -q ."

echo "== L2 full queue behaviour with fcntl made unavailable"
reset; export PYTHONPATH="$NOFC"
chk "stub really blocks fcntl" "! python3 -c 'import fcntl' 2>/dev/null"
for i in $(seq 1 25); do $Q add --url "https://e.com/p$i" >/dev/null 2>&1 & done; wait
chk "25 parallel adds -> 25 jobs, unique ids" "[[ \$($Q list --json | python3 -c 'import sys,json;j=json.load(sys.stdin);print(len(j),len({x[\"id\"] for x in j}))') == '25 25' ]]"
reset; for i in $(seq 1 15); do $Q add --url "https://e.com/same" >/dev/null 2>&1 & done; wait
chk "15 parallel adds of one link -> exactly 1 job" "[[ \$($Q stats) == 'pending=1 running=0 done=0 failed=0' ]]"
reset; for i in 1 2 3; do $Q add --url "https://e.com/o$i" >/dev/null; done
l=$($Q next | cut -f1); $Q done "$l"; l2=$($Q next | cut -f1)
chk "FIFO + one-at-a-time work without locks" "[[ $l == 1 && $l2 == 2 ]] && ! $Q next >/dev/null 2>&1"
$Q recover >/dev/null; chk "recover works" "[[ \$($Q stats) == 'pending=2 running=0 done=1 failed=0' ]]"
unset PYTHONPATH

echo "== L3 stale / dead / killed lock owners"
reset; mkdir -p "$S/data/queue/.lock.d"; sleep 0.01 & DP=$!; wait $DP; echo $DP > "$S/data/queue/.lock.d/pid"
start=$(date +%s.%N); $Q add --url "https://e.com/a" >/dev/null 2>&1; rc=$?; el=$(awk -v a=$start -v b=$(date +%s.%N) 'BEGIN{printf "%.1f",b-a}')
chk "lock left by a DEAD process is taken over at once (${el}s)" "[[ $rc == 0 ]] && awk -v e=$el 'BEGIN{exit !(e<2)}' && [[ ! -d '$S/data/queue/.lock.d' ]]"
reset; mkdir -p "$S/data/queue/.lock.d"; touch -d '1 minute ago' "$S/data/queue/.lock.d"
chk "abandoned lock with no owner info (old) is taken over" "$Q add --url https://e.com/b >/dev/null 2>&1"
reset; mkdir -p "$S/data/queue"
python3 - "$S" <<'PY' &
import sys, time; sys.path.insert(0, sys.argv[1]); import qctl
qctl.QDIR = __import__("os").environ["QUEUE_DIR"]
with qctl.Locked():
    time.sleep(60)
PY
HP=$!; sleep 1
chk "a live holder blocks others: 'queue is busy', exit 4, no traceback" "QUEUE_LOCK_TIMEOUT=2 $Q add --url https://e.com/c > '$T/busy.out' 2>&1; [[ \$? == 4 ]] && grep -q 'queue is busy' '$T/busy.out' && ! grep -q Traceback '$T/busy.out'"
kill -9 $HP; wait $HP 2>/dev/null
chk "after kill -9 of the holder, the next call proceeds" "$Q add --url https://e.com/c >/dev/null 2>&1 && [[ \$($Q stats) == 'pending=1 running=0 done=0 failed=0' ]]"
chk "no lock directory left behind" "[[ ! -d '$S/data/queue/.lock.d' ]]"
chk "no half-written job files left" "[[ -z \$(ls -A '$S/data/queue' | grep -E '\\.tmp|stale') ]]"

echo "== L4 selftest (the check you run on the phone)"
reset; mkdir -p "$S/data"
out=$($Q selftest 2>&1); rc=$?
chk "selftest passes (rc 0, SELFTEST PASS)" "[[ $rc == 0 ]] && grep -q 'SELFTEST PASS' <<< \"\$out\"" 
chk "selftest cleans up after itself" "[[ -z \$(ls '$S/data' | grep selftest) ]]"
chk "selftest also passes with fcntl blocked" "PYTHONPATH='$NOFC' $Q selftest >/dev/null 2>&1"
chk "q selftest works through q.sh" "bash '$S/q.sh' selftest 2>&1 | grep -q 'SELFTEST PASS'"

echo "== L5 broken storage: one clear message, nothing touched"
reset; : > "$T/afile"; export QUEUE_DIR="$T/afile/queue"      # a path below a regular file: cannot be created
$Q add --url https://e.com/x > "$T/b1.out" 2>&1; rc=$?
chk "qctl: exit 4, one line, no traceback" "[[ $rc == 4 ]] && grep -q 'queue storage error' '$T/b1.out' && ! grep -q Traceback '$T/b1.out' && [[ \$(wc -l < '$T/b1.out') == 1 ]]"
for n in a b c; do cp /dev/null "$T/media/DCIM/TikTok/v$n.mp4"; echo data > "$T/media/DCIM/TikTok/v$n.mp4"; done; touch -d '1 minute ago' "$T/media/DCIM/TikTok/"*
bash "$S/q.sh" scan > "$T/b2.out" 2>&1; rc=$?
chk "q scan: stops at the FIRST error (1 message for 3 files), exit 1" "[[ $rc == 1 && \$(grep -c 'Could not queue' '$T/b2.out') == 1 ]]"
chk "all 3 originals untouched" "[[ \$(ls '$T/media/DCIM/TikTok' | wc -l) == 3 ]]"
bash "$S/master_run.sh" > "$T/b3.out" 2>&1; rc=$?
chk "tiktok: says the queue is not working, exit 1, originals untouched" "[[ $rc == 1 ]] && grep -q 'queue is not working' '$T/b3.out' && ! grep -q Traceback '$T/b3.out' && [[ \$(ls '$T/media/DCIM/TikTok' | wc -l) == 3 ]]"
( cd "$S" && bash worker.sh > "$T/b4.out" 2>&1 ); rc=$?
chk "worker: exit 1 with a clear message (does not claim it finished)" "[[ $rc == 1 ]] && grep -qE 'not usable|unavailable' '$T/b4.out' && ! grep -q 'Queue finished' '$T/b4.out'"
export QUEUE_DIR="$S/data/queue"

echo "== L6 readers during writers (Web UI polls while jobs are added)"
reset; ( for i in $(seq 1 30); do $Q list --json >/dev/null 2>&1; $Q stats >/dev/null 2>&1; done ) & RP=$!
for i in $(seq 1 30); do $Q add --url "https://e.com/r$i" >/dev/null 2>&1 & done; wait
chk "30 jobs, counter consistent, no stray files" "[[ \$($Q stats) == 'pending=30 running=0 done=0 failed=0' && \$(cat '$S/data/queue/.seq') == 30 && -z \$(ls -A '$S/data/queue' | grep -E '\\.tmp|\\.lock') ]]"

echo; echo "RESULT: $pass passed, $failn failed"; exit $(( failn > 0 ))
