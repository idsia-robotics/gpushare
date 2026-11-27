#!/bin/bash
# Simulation tests for gpuq in a scratch root (no real GPUs touched).
# usage: tests/sim.sh bin/gpuq
set -u
G=${1:?path to gpuq}
T=$(mktemp -d "${TMPDIR:-/tmp}/gpuqsim.XXXX")
export GPUQ_ROOT=$T GPUQ_NO_SMI=1
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID GPUQ_SESSION
export XDG_STATE_HOME=$T/state
for i in 0 1 2 3 4; do
  mkdir -p $T/gpu$i; chmod 1777 $T/gpu$i; : > $T/gpu$i/.mutex
  printf 'index: %s\nuuid: GPU-fake-%s\nname: Fake 4080\npci_bus_id: x\nmemory_total_mib: 16376\n' $i $i > $T/gpu$i/.gpu-info
done
mkdir -p $T/hosts
printf '{"gpus":{"4":{"uuid":"GPU-fake-4","assigned":"%s","name":"me"}}}' "$USER" > $T/hosts/$(hostname -s).json

pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
expect() { # expect <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
sess() { sleep 100000 >/dev/null 2>&1 & echo $!; }   # fake long-lived agent session

P1=$(sess); P2=$(sess); P3=$(sess)
echo "== numbering"
A=$($G join 4 a --mem 4G --duration 1h --reason t --pid $P1 2>/dev/null)
B=$($G join 4 b --mem 4G --duration 1h --reason t --pid $P2 2>/dev/null)
C=$($G join 4 c --mem 4G --duration 1h --reason t --pid $P3 2>/dev/null)
expect "first is 1000" "1000-$USER-a" "$A"
expect "second is 1010" "1010-$USER-b" "$B"
expect "third is 1020" "1020-$USER-c" "$C"
expect "lock mode 666" "666" "$(stat -c %a $T/gpu4/$A)"
grep -q '^assigned: yes' $T/gpu4/$A && ok "assigned detected from hosts json" || bad "assigned flag"
$G status 4 | grep "$A" | grep -q '\[assigned user\]' && ok "status marks the assigned user (by file owner)" || bad "assigned mark"

echo "== turn order"
$G check $A >/dev/null; expect "A's turn" 0 $?
$G check $B >/dev/null; expect "B waits" 1 $?
$G start $A >/dev/null 2>&1; expect "A start" 0 $?
$G check $B >/dev/null; expect "B waits while A runs" 1 $?
$G leave $A >/dev/null; [[ ! -e $T/gpu4/$A ]] && ok "A removed" || bad "A still there"
$G check $B >/dev/null; expect "B's turn after A left" 0 $?

echo "== front / no preemption"
P4=$(sess)
$G start $B >/dev/null 2>&1
F=$($G join 4 urgent --front --mem 4G --duration 1h --reason deadline --pid $P4 2>/dev/null)
expect "front number = lowest-10" "1000-$USER-urgent" "$F"
$G check $F >/dev/null; expect "front job waits for running B (no auto-preempt)" 1 $?
$G check $C >/dev/null; expect "C behind front job" 1 $?
$G ping $B "please yield" >/dev/null; grep -q "PING please yield" $T/gpu4/$B && ok "ping appended" || bad "ping"
$G leave $B >/dev/null
$G check $F >/dev/null; expect "front job next" 0 $?

echo "== stale"
kill $P4; sleep 0.2
$G status 4 | grep -q "$F *STALE" && ok "status shows stale" || bad "stale not shown: $($G status 4)"
$G check $C >/dev/null; expect "C not blocked by stale lock" 0 $?
$G check $F >/dev/null; expect "stale lock check exit 3" 3 $?
P5=$(sess); $G adopt $F --pid $P5 >/dev/null
$G check $F >/dev/null; expect "adopted lock valid again" 0 $?
$G prune >/dev/null; $G leave $F >/dev/null; $G leave $C >/dev/null

echo "== sharing"
S1=$($G join 2 s1 --share --mem 4G --duration 1h --reason t --pid $P1 2>/dev/null)
S2=$($G join 2 s2 --share --mem 4G --duration 1h --reason t --pid $P2 2>/dev/null)
S3=$($G join 2 s3 --share --mem 10G --duration 1h --reason t --pid $P3 2>/dev/null)
$G start $S1 >/dev/null 2>&1
$G check $S2 >/dev/null; expect "S2 co-runs (4G+4G)" 0 $?
$G start $S2 >/dev/null 2>&1
$G check $S3 | grep -q "cannot share" && ok "S3 10G refused (budget)" || bad "S3 should be refused"
$G leave $S3 >/dev/null
N1=$($G join 2 n1 --mem 2G --duration 1h --reason t --pid $P3 2>/dev/null)
$G check $N1 | grep -q busy && ok "non-sharing job waits" || bad "non-share should wait"
$G leave $S1 >/dev/null; $G leave $S2 >/dev/null; $G leave $N1 >/dev/null

echo "== unregistered usage (fake nvidia-smi)"
FS=$T/fakesmi; mkdir -p $FS
printf '3, GPU-fake-3, 16376, 1412, 0\n4, GPU-fake-4, 16376, 1, 0\n' > $FS/gpus.csv
printf 'GPU-fake-3, 4242, 1412, bob\n' > $FS/apps.csv
U=$($G join 3 u --mem 4G --duration 1h --reason t --pid $P1 2>/dev/null)
GPUQ_NO_SMI=0 GPUQ_FAKE_SMI=$FS $G check $U | grep -q unregistered && ok "unregistered blocks" || bad "unregistered"
GPUQ_NO_SMI=0 GPUQ_FAKE_SMI=$FS $G check --ignore-unregistered $U >/dev/null; expect "--ignore-unregistered + memory fits" 0 $?
printf '3, GPU-fake-3, 16376, 14000, 0\n' > $FS/gpus.csv
GPUQ_NO_SMI=0 GPUQ_FAKE_SMI=$FS $G check --ignore-unregistered $U | grep -q "free" && ok "smi free-memory check" || bad "free mem check"
GPUQ_NO_SMI=0 GPUQ_FAKE_SMI=$FS $G status 3 | grep -q UNREGISTERED && ok "status flags unregistered" || bad "status unreg"
$G leave $U >/dev/null

echo "== no-show at the front is skipped after the grace period"
export GPUQ_TURN_GRACE=1
X=$($G join 0 noshow --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null)
Y=$($G join 0 behind --mem 1G --duration 1m --reason t --pid $P2 2>/dev/null)
$G check $Y >/dev/null; expect "Y waits behind X" 1 $?
grep -q " TURN " $T/gpu0/$X && ok "X got a TURN line" || bad "no TURN on X"
sleep 1.6
$G check $Y >/dev/null; expect "Y may go after X's grace period" 0 $?
grep -q " SKIP " $T/gpu0/$X && ok "X marked SKIP" || bad "no SKIP on X"
$G status 0 | grep -q "$X *SKIPPED" && ok "status shows SKIPPED" || bad "status skip: $($G status 0)"
$G start $Y >/dev/null 2>&1
$G check $X | grep -q busy && ok "X back: waits for running Y" || bad "X back"
grep -q "STATUS queued (back" $T/gpu0/$X && ok "owner's check reactivates X" || bad "no reactivation"
Z=$($G join 0 third --mem 1G --duration 1m --reason t --pid $P3 2>/dev/null)
$G leave $Y >/dev/null
$G check $Z >/dev/null; expect "Z waits: reactivated X keeps its priority" 1 $?
$G check $X >/dev/null; expect "X's turn after Y" 0 $?
$G leave $X >/dev/null; $G leave $Z >/dev/null
unset GPUQ_TURN_GRACE

echo "== run"
R=$($G join 4 r --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null)
OUT=$($G run $R -- sh -c 'echo "VIS=$CUDA_VISIBLE_DEVICES ORDER=$CUDA_DEVICE_ORDER JOB=$GPUQ_JOB"; exit 7' 2>/dev/null)
RC=$?
expect "run env" "VIS=GPU-fake-4 ORDER=PCI_BUS_ID JOB=$R" "$OUT"
expect "run exit code" 7 $RC
[[ ! -e $T/gpu4/$R ]] && ok "run removed lock" || bad "lock left after run"

echo "== run waits, then runs; SIGTERM forwarded and cleans up"
W1=$($G join 4 w1 --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null)
W2=$($G join 4 w2 --mem 1G --duration 1m --reason t --pid $P2 2>/dev/null)
$G start $W1 >/dev/null 2>&1
$G run --poll 0.5 $W2 -- sleep 1000 2>$T/run.err &
RP=$!
sleep 1.5; grep -q "waiting" $T/run.err && ok "run is waiting" || bad "run not waiting: $(cat $T/run.err)"
$G leave $W1 >/dev/null; sleep 1.5
grep -q "STATUS running pid=$RP" $T/gpu4/$W2 && ok "run claimed" || bad "not claimed: $(cat $T/gpu4/$W2)"
kill -TERM $RP; wait $RP; RC=$?
expect "SIGTERM -> 128+15" 143 $RC
[[ ! -e $T/gpu4/$W2 ]] && ok "lock removed after SIGTERM" || bad "lock left after SIGTERM"

echo "== run joins the queue by itself"
OUT=$($G run 3 inline --mem 1G --duration 1m --reason t --pid $P1 -- sh -c 'echo "VIS=$CUDA_VISIBLE_DEVICES"' 2>/dev/null)
expect "run <gpu> <job> joins and runs" "VIS=GPU-fake-3" "$OUT"
expect "its lock is removed afterwards" "" "$(ls $T/gpu3 | grep -E '^[0-9]{4}-')"
$G run 3 inline2 --mem 1G -- true 2>&1 | grep -q "needs --duration, --reason" && ok "missing join flags rejected" || bad "missing flags accepted"
$G run 3 inline3 --mem 1G --duration 1m --reason t 2>&1 | grep -q "usage: gpuq run" && ok "missing -- command rejected" || bad "missing command accepted"
expect "nothing left behind by rejected runs" "" "$(ls $T/gpu3 | grep -E '^[0-9]{4}-')"
B1=$($G join 3 blocker --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null); $G start $B1 >/dev/null 2>&1
$G run --poll 0.3 3 waiter --mem 1G --duration 1m --reason t --pid $P2 -- true 2>/dev/null &
RP=$!; sleep 1
ls $T/gpu3 | grep -q waiter && ok "inline run waits in the queue" || bad "no waiter lock"
kill -TERM $RP; wait $RP; RC=$?
expect "SIGTERM while waiting -> 143" 143 $RC
ls $T/gpu3 | grep -q waiter && bad "inline lock left after SIGTERM" || ok "lock it created is removed if stopped before starting"
$G leave $B1 >/dev/null

echo "== watch"
K=$($G join 1 k --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null)
$G watch --all --poll 0.2 $K > $T/watch.out 2>&1 &
WP=$!; sleep 0.5
$G ping $K "hello from test" >/dev/null; sleep 0.6
$G leave $K >/dev/null; sleep 0.6
wait $WP
grep -q "hello from test" $T/watch.out && ok "watch saw ping" || bad "watch missed ping: $(cat $T/watch.out)"
grep -q "was removed" $T/watch.out && ok "watch exits on removal" || bad "watch didn't exit"

echo "== race: 12 concurrent joins"
for i in $(seq 1 12); do $G join 0 race$i --mem 1G --duration 1m --reason t --pid $P1 >/dev/null 2>&1 & done; wait
NUMS=$(ls $T/gpu0 | grep -E '^[0-9]{4}-' | cut -c1-4 | sort | uniq -d | wc -l)
expect "no duplicate numbers" 0 $NUMS
expect "12 locks created" 12 $(ls $T/gpu0 | grep -cE '^[0-9]{4}-')
for f in $(ls $T/gpu0 | grep -E '^[0-9]{4}-'); do $G leave $f >/dev/null; done

echo "== multi-gpu, renumber, umask"
M=$( (umask 077; $G join 0,1 multi --mem 1G --duration 1m --reason t --pid $P1 2>/dev/null) )
[[ -e $T/gpu0/$M && -e $T/gpu1/$M ]] && ok "multi-gpu lock in both dirs" || bad "multi"
expect "umask 077 still gives 666" 666 "$(stat -c %a $T/gpu1/$M)"
M2=$($G renumber $M 500 testing)
expect "renumber" "0500-$USER-multi" "$M2"
[[ -e $T/gpu0/$M2 && -e $T/gpu1/$M2 && ! -e $T/gpu0/$M ]] && ok "renamed in both dirs" || bad "renumber files"
OUT=$($G start $M2 2>/dev/null | tail -1)
expect "multi-gpu env" "export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=GPU-fake-0,GPU-fake-1" "$OUT"
$G leave $M2 >/dev/null

echo "== identity comes from the file owner, not from names or headers"
printf 'user: mallory\nassigned: yes\n--- log ---\n' > $T/gpu1/0500-mallory-fake; chmod 666 $T/gpu1/0500-mallory-fake
$G status 1 | grep 0500-mallory-fake | grep -q "file owned by $USER" && ok "forged file name flagged" || bad "forged name not flagged"
$G status 1 | grep 0500-mallory-fake | grep -q 'assigned user' && bad "forged 'assigned: yes' header trusted" || ok "header 'assigned: yes' not trusted"
rm -f $T/gpu1/0500-mallory-fake

echo "== sessions: several agents under one user"
SA=$(sess); SB=$(sess)
ga() { GPUQ_SESSION=alpha CLAUDE_PID=$SA $G "$@"; }   # two chats of the same user
gb() { GPUQ_SESSION=beta  CLAUDE_PID=$SB $G "$@"; }
LA=$(ga join 2 sa --mem 1G --duration 2h --reason t 2>/dev/null)
grep -q '^session: alpha$' $T/gpu2/$LA && ok "header names the session" || bad "no session header"
grep -q "$USER@$(hostname -s)/alpha STATUS queued" $T/gpu2/$LA && ok "log lines carry the session" || bad "no session tag"
gb ping $LA --need-by +1h 'need it soon, "really"' >/dev/null
grep -q "/beta PING need-by=20" $T/gpu2/$LA && ok "ping with --need-by" || bad "need-by: $(tail -1 $T/gpu2/$LA)"
OUT=$(ga inbox --once)
echo "$OUT" | grep -q "PING on $LA from $USER@$(hostname -s)/beta (unverified): \"need it soon, \\\\\"really\\\\\"\" need-by" \
  && ok "inbox shows a sibling session's ping, quoted" || bad "inbox: $OUT"
echo "$OUT" | grep -q "answer: gpuq reply $LA" && ok "inbox says how to answer" || bad "no hint: $OUT"
OUT=$(ga inbox --once)
echo "$OUT" | grep -q "PING on" && bad "inbox repeated a delivered ping" || ok "each event is delivered once"
echo "$OUT" | grep -q "PENDING on $LA: unanswered PING" && ok "unanswered ping stays pending" || bad "pending: $OUT"
gb leave $LA >/dev/null 2>&1; expect "sibling can't leave a live lock" 4 $?
gb renumber $LA 900 x >/dev/null 2>&1; expect "sibling can't renumber it" 4 $?
gb start $LA >/dev/null 2>&1; expect "sibling can't start it" 4 $?
gb adopt $LA >/dev/null 2>&1; expect "sibling can't adopt it while its session lives" 4 $?
[[ -e $T/gpu2/$LA ]] && ok "lock untouched" || bad "lock gone"
ga mine | grep "$LA" | grep -q '\[this session\]' && ok "mine marks this session" || bad "mine: $(ga mine)"
gb mine | grep "$LA" | grep -q '\[session alpha\]' && ok "mine marks the sibling's lock" || bad "mine b: $(gb mine)"
$G status 2 | grep "$LA" | grep -q "UNANSWERED PING from $USER/beta" && ok "status flags the unanswered ping" || bad "status: $($G status 2)"
ga reply $LA --leave-by +2s "ok, yielding soon" >/dev/null
OUT=$(gb inbox --once)
echo "$OUT" | grep -q "ACK on $LA from .*/alpha (unverified): \"ok, yielding soon\" leave-by .* -> this answers your ping" \
  && ok "pinger's inbox gets the answer" || bad "answer: $OUT"
$G status 2 | grep "$LA" | grep -q "leaving by" && ok "status shows the promise" || bad "promise: $($G status 2)"
$G status 2 | grep "$LA" | grep -q UNANSWERED && bad "still unanswered after reply" || ok "reply answers the ping"
sleep 2.5
ga inbox --once | grep -q "DUE on $LA: you promised to leave by" && ok "inbox reminds when the promise is due" || bad "no DUE"
$G status 2 | grep "$LA" | grep -q "OVERDUE" && ok "status shows overdue promise" || bad "overdue: $($G status 2)"
ga watch --poll 0.2 $LA > $T/watch2.out 2>&1 &
WP=$!; sleep 0.5; gb ping $LA "second" >/dev/null; sleep 0.6; kill $WP; wait $WP 2>/dev/null
grep -q '"second"' $T/watch2.out && ok "watch shows sibling pings without --all" || bad "watch2: $(cat $T/watch2.out)"
ga inbox --once >/dev/null   # drain
ga inbox --next --poll 0.2 > $T/next.out 2>&1 &
NP=$!; sleep 0.6; gb note $LA "fyi" >/dev/null; sleep 0.6
kill -0 $NP 2>/dev/null && { bad "inbox --next did not exit"; kill $NP; } || ok "inbox --next exits on the next event"
wait $NP 2>/dev/null
grep -q 'NOTE on .*"fyi"' $T/next.out && ok "inbox --next prints it" || bad "next: $(cat $T/next.out)"
kill $SA; sleep 0.2
$G status 2 | grep -q "$LA *STALE" && ok "session gone: lock stale" || bad "not stale"
SA=$(sess)
ga mine >/dev/null
grep -q "session=alpha (resumed)" $T/gpu2/$LA && ok "resumed session re-attaches its lock" || bad "no reattach"
ga check $LA >/dev/null; expect "lock valid again after resume" 0 $?
kill $SA; sleep 0.2
gb adopt $LA >/dev/null; expect "sibling may adopt a lock whose session is gone" 0 $?
gb mine | grep "$LA" | grep -q '\[this session\]' && ok "adopt hands the lock over" || bad "adopt: $(gb mine)"
SA=$(sess)
LB=$(ga join 2 sb --mem 1G --duration 1h --reason t 2>/dev/null)
gb leave --force $LB >/dev/null; expect "--force overrides" 0 $?
gb inbox --once >/dev/null
ga ping $LA "a ping from alpha" >/dev/null
ga inbox --once >/dev/null
gb leave $LA >/dev/null
OUT=$(ga inbox --once)
echo "$OUT" | grep -q "REMOVED on $LA: a lock you pinged was removed" && ok "pinger hears the lock is gone" || bad "removed: $OUT"

echo "== a sibling's ping doesn't bring a skipped lock back"
X=$(GPUQ_TURN_GRACE=1 ga join 1 nsx --mem 1G --duration 1m --reason t 2>/dev/null)
Y=$(GPUQ_TURN_GRACE=1 gb join 1 nsy --mem 1G --duration 1m --reason t 2>/dev/null)
GPUQ_TURN_GRACE=1 gb check $Y >/dev/null; sleep 1.6; GPUQ_TURN_GRACE=1 gb check $Y >/dev/null
gb ping $X "are you still there?" >/dev/null
GPUQ_TURN_GRACE=1 $G status 1 | grep -q "$X *SKIPPED" && ok "still skipped after a sibling's ping" || bad "unskipped: $($G status 1)"
GPUQ_TURN_GRACE=1 ga check $X >/dev/null
grep -q "STATUS queued (back" $T/gpu1/$X && ok "its own session brings it back" || bad "no reactivation"
gb leave $Y >/dev/null; ga leave $X >/dev/null

echo "== old-format locks and lines"
cat > $T/gpu3/0900-$USER-old <<EOF
# gpuq lock v1. Protocol: x
user: $USER
created: 2026-11-26T10:00:00+01:00
owner_pid: $SB
mem: 1G
duration: 1h
reason: from an older gpuq
--- log ---
2026-11-26T10:00:00+01:00 $USER@$(hostname -s) STATUS queued
2026-11-26T10:05:00+01:00 bob@$(hostname -s) PING old style ping
EOF
chmod 666 $T/gpu3/0900-$USER-old
ga mine | grep 0900-$USER-old | grep -q '\[this session\]' && ok "lock without session belongs to all your sessions" || bad "old mine"
ga inbox --once | grep -q 'PING on 0900-.*from bob@.*"old style ping"' && ok "old-format ping in inbox" || bad "old inbox"
gb leave 0900-$USER-old >/dev/null; expect "old lock can be left" 0 $?

echo "== machine-readable output and hints"
LJ=$(ga join 0 js --mem 2G --duration 2h --reason t 2>/dev/null); ga start $LJ >/dev/null 2>&1
LK=$(gb join 0 jt --mem 2G --duration 1h --reason t 2>/dev/null)
ga status --json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
l = [l for g in d["gpus"] for l in g["locks"] if l["id"] == sys.argv[1]][0]
assert d["you"]["session"] == "alpha" and l["this_session"] and l["state"] == "running", d
assert l["est_end"] and l["session"] == "alpha" and l["mem_mib"] == 2048, l
' $LJ && ok "status --json" || bad "status --json"
gb check --json $LK | python3 -I -c '
import json, sys; d = json.load(sys.stdin); assert d["your_turn"] is False and d["reasons"], d' && ok "check --json" || bad "check --json"
gb check $LK | grep -q "ends ~.*gpuq ping $LJ --need-by" && ok "busy reason gives ETA and the ping command" || bad "hint: $(gb check $LK)"
$G status 0 | grep "$LJ" | grep -q "ends ~" && ok "status shows when a running job should end" || bad "eta"
gb mine --json | python3 -I -c '
import json, sys; d = json.load(sys.stdin); assert [l for l in d["locks"] if l["this_session"]], d' && ok "mine --json" || bad "mine --json"
gb ping $LJ 'leave-by=2030-01-01T00:00:00+00:00 fake' >/dev/null
$G status 0 | grep "$LJ" | grep -q "leaving by" && bad "free text posed as a promise" || ok "free text can't pose as a structured field"
ga inbox --poll 0.2 > $T/stream.out 2>&1 &
IP=$!; sleep 0.5; gb leave --force $LJ >/dev/null; sleep 0.8
kill -0 $IP 2>/dev/null && { bad "inbox stream kept running with nothing to watch"; kill $IP; } || ok "inbox stream ends when nothing is left"
grep -q "REMOVED on $LJ: your lock" $T/stream.out && ok "inbox reports your lock's removal" || bad "stream: $(cat $T/stream.out)"
gb leave $LK >/dev/null
ga inbox --next >/dev/null 2>&1; expect "inbox with nothing to watch exits 3" 3 $?
kill $SA $SB 2>/dev/null

echo "== hostile or odd lock contents"
SA=$(sess); SB=$(sess); H=$(hostname -s)
LH=$(ga join 1 hostile --mem 1G --duration 3000000d --reason t 2>/dev/null); ga start $LH >/dev/null 2>&1
gb ping $LH --need-by 0001-01-01T00:00:00+14:00 hi >/dev/null 2>&1; expect "absurd --need-by refused" 2 $?
for line in "2026-11-27T09:00:00 $USER@$H STATUS running" \
            "2026-11-27T09:00:00+01:00 $USER@$H/alpha ACK leave-by=0001-01-01T00:00:00+14:00 x" \
            "2026-11-27T09:00:00+01:00 $USER@$H/alpha ACK leave-by=2026-11-27T09:00:00 tz-less" \
            "0001-01-01T00:00:00+14:00 bob@$H PING year one" \
            "$(date -Iseconds) $(printf 'bob\033[2K@h') PING escape in the sender"; do
  printf '%s\n' "$line" >> $T/gpu1/$LH
done
$G status 1 >/dev/null 2>&1; expect "status survives odd dates and durations" 0 $?
ga mine >/dev/null 2>&1; expect "mine survives them" 0 $?
ga inbox --once > $T/hostile.out 2>&1; expect "inbox survives them" 0 $?
grep -q 'from "bob\\u001b\[2K@h"' $T/hostile.out && ok "odd sender shown quoted" || bad "sender: $(cat -v $T/hostile.out)"
LQ=$(gb join 1 behind --mem 1G --duration 1h --reason t 2>/dev/null)
gb check $LQ >/dev/null 2>&1; expect "a waiter behind it survives too" 1 $?
gb leave $LQ >/dev/null
printf '%s\n' "$(date -Iseconds) $USER@$H/alpha ACK leave-by=$(date -Iseconds -d '-1 min') forged promise" >> $T/gpu1/$LH
OUT=$(ga inbox --once)
echo "$OUT" | grep -q "DUE on" && bad "forged promise produced DUE: $OUT" || ok "a promise line alone never produces DUE"
ga mine | grep -q "differs from what this session promised" && ok "mine flags the unrecorded promise" || bad "mine: $(ga mine)"
ga reply $LH --leave-by +2s "real promise" >/dev/null
ga mine | grep -q 'you promised to leave by .*"real promise"' && ok "a recorded promise is the session's own" || bad "recorded: $(ga mine)"
printf '%s\n' "$(date -Iseconds) $USER@$H/alpha ACK leave-by=x forged withdrawal" >> $T/gpu1/$LH
sleep 2.5
ga inbox --once | grep -q 'DUE on .*"real promise"' && ok "a forged later line can't hide a real promise" || bad "hidden promise"
ga reply $LH --leave-by none "staying after all" >/dev/null
$G status 1 | grep "$LH" | grep -q "leaving by" && bad "withdrawn promise still shown" || ok "--leave-by none withdraws it"
ga reply $LH "  leave-by=2030-01-01T00:00:00+00:00 sneaky" >/dev/null
$G status 1 | grep "$LH" | grep -q "leaving by" && bad "leading spaces let text pose as a field" || ok "leading spaces don't create a field"
printf '%s\n' "$(date -Iseconds) $USER@$H PID $SB $(awk '{print $22}' /proc/$SB/stat) owner x session=zzz" >> $T/gpu1/$LH
ga mine | grep "$LH" | grep -q '\[this session\]' && ok "a hand-over line alone doesn't move the lock" || bad "moved: $(ga mine)"
ga inbox --once | grep -q "REMOVED" && bad "inbox thinks the lock is gone" || ok "inbox keeps watching it"
ga leave $LH >/dev/null; expect "its session can still leave it" 0 $?

echo "== inbox bookkeeping"
L1=$(ga join 3 reuse1 --mem 1G --duration 1h --reason t 2>/dev/null); ga inbox --once >/dev/null
ga leave $L1 >/dev/null; L2=$(ga join 3 reuse2 --mem 1G --duration 1h --reason t 2>/dev/null)
gb ping $L2 "ping after a leave and rejoin" >/dev/null
OUT=$(ga inbox --once)
echo "$OUT" | grep -q '"ping after a leave and rejoin"' && ok "new lock's ping delivered (inode reuse)" || bad "reuse: $OUT"
echo "$OUT" | grep -q "REMOVED on $L1" && bad "own leave reported: $OUT" || ok "your own leave is no news (inode reuse too)"
ga leave $L2 >/dev/null; ga inbox --once >/dev/null
LM=$(ga join 0,1 multi2 --mem 1G --duration 1h --reason t 2>/dev/null); ga inbox --once >/dev/null
gb ping $LM "one ping, two GPUs" >/dev/null
expect "multi-GPU ping delivered once" 1 "$(ga inbox --once | grep -c '\] PING on .*one ping, two GPUs')"
gb leave --force $LM >/dev/null
expect "multi-GPU removal reported once" 1 "$(ga inbox --once | grep -c "REMOVED on $LM")"
LR=$(ga join 3 answered --mem 1G --duration 1h --reason t 2>/dev/null)
gb ping $LR "old question" >/dev/null; ga reply $LR "old answer" >/dev/null
XDG_STATE_HOME=$T/fresh ga inbox --once | grep -q "old question" && bad "fresh inbox replays answered pings" || ok "fresh inbox skips pings already answered"
ga leave $LR >/dev/null
mkdir -p $T/state/gpuq; touch $T/state/gpuq/inbox-$H-gone.json
touch -d '20 days ago' $T/state/gpuq/inbox-$H-gone.json $T/state/gpuq/inbox-$H-alpha.json.lock
LP=$(ga join 3 pruner --mem 1G --duration 1h --reason t 2>/dev/null); ga inbox --once >/dev/null; ga leave $LP >/dev/null
[[ -e $T/state/gpuq/inbox-$H-alpha.json.lock ]] && ok "inbox keeps its own lock file" || bad "own .lock deleted"
[[ ! -e $T/state/gpuq/inbox-$H-gone.json ]] && ok "old sessions' state is cleaned up" || bad "old state kept"

echo "== resume, hand-over and terminals"
LS=$(ga join 4 resumed-run --mem 1G --duration 1h --reason t 2>/dev/null); ga start $LS >/dev/null 2>&1
kill $SA; sleep 0.2; SA=$(sess); ga mine >/dev/null
$G status 4 | grep -q "$LS *STALE" && ok "a dead running job is not revived on resume" || bad "revived: $($G status 4)"
ga prune >/dev/null
LC=$(ga join 4 handback --mem 1G --duration 1h --reason t 2>/dev/null); ga inbox --once >/dev/null
gb adopt --force $LC >/dev/null
ga inbox --once | grep -q "HANDED-OVER on $LC: your lock is now held by your session beta" \
  && ok "the old holder hears of the hand-over" || bad "handover event: $(ga inbox --once)"
kill $SB; sleep 0.2
ga adopt $LC >/dev/null 2>&1; expect "after a hand-over only the new holder's process counts" 0 $?
SB=$(sess); LT=$(gb join 4 term --mem 1G --duration 1h --reason t 2>/dev/null)
$G leave $LT >/dev/null 2>&1; expect "a non-agent script can't act on an agent's live lock" 4 $?
script -qec "$G leave $LT" /dev/null > $T/term.out 2>&1; expect "a person at a terminal may" 0 $?
grep -q "going ahead because you are typing in a terminal" $T/term.out && ok "with a warning" || bad "no warning: $(cat $T/term.out)"
$G join 4 rootpid --mem 1G --duration 1h --reason t --pid 1 >/dev/null 2>&1; expect "an owner pid that isn't yours is refused" 2 $?
ga leave $LC >/dev/null
setsid -f $G join 4 detached --mem 1G --duration 1h --reason t >/dev/null 2>&1; sleep 0.5
D=$(ls $T/gpu4 | grep detached)
grep -q '^owner_pid: 1$' $T/gpu4/$D && bad "detached join owned by init" || ok "detached join is not owned by init"
$G prune >/dev/null
$G join 4 dur --mem 1G --duration 1.2.3h --reason t --pid $SA >/dev/null 2>&1
$G start 1.*-dur >/dev/null 2>&1; true
$G status 4 | grep dur | grep -q "ends ~" && bad "1.2.3h read as a duration" || ok "malformed duration ignored"
for f in $(ls $T/gpu4 | grep -E '^[0-9]{4}-'); do $G leave --force $f >/dev/null 2>&1; done
kill $SA $SB 2>/dev/null

echo "== claude code hooks (plugins/gpushare)"
SA=$(sess); SB=$(sess); SC=$(sess)
IDA=aaaa1111-0000-4000-8000-000000000001; IDB=bbbb2222-0000-4000-8000-000000000002
IDC=cccc3333-0000-4000-8000-000000000003; IDA2=dddd4444-0000-4000-8000-000000000004
ca() { CLAUDE_CODE_SESSION_ID=$IDA CLAUDE_PID=$SA $G "$@"; }   # two Claude Code chats
cb() { CLAUDE_CODE_SESSION_ID=$IDB CLAUDE_PID=$SB $G "$@"; }
hk() { # hk <session id> <claude pid> <event> [extra json]: what Claude Code would run
  printf '{"session_id":"%s","cwd":"/tmp"%s}' "$1" "${4:-}" | CLAUDE_PID=$2 $G hook $3 --poll 0.2; }
ctx() { python3 -I -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else "")'; }
reason() { python3 -I -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t) if t.strip() else {}; print(d.get("decision",""), d.get("reason","").replace("\n", " | "))'; }
expect "session start with nothing to say is silent" "" "$(hk $IDC $SC session-start ',"source":"startup"')"
mkdir -p $T/etc; cp "$(dirname $G)/../etc/claude-code-CLAUDE.md" $T/etc/
if grep -qs gpushare:begin /etc/claude-code/CLAUDE.md; then
  expect "no pointer when the admin installed it" "" "$(hk $IDC $SC session-start ',"source":"startup"')"
else
  hk $IDC $SC session-start ',"source":"startup"' | ctx | grep -q "Shared GPUs on this server" \
    && ok "session start gives the pointer when the admin hasn't installed it" || bad "no pointer"
fi
LA=$(ca join 2 hooked --mem 1G --duration 1h --reason t 2>/dev/null); ca start $LA >/dev/null 2>&1
hk $IDA $SA tool | ctx > $T/h.out; expect "no news, no context" "" "$(grep -v 'Shared GPUs' $T/h.out)"
cb ping $LA "may I have gpu2 at five?" >/dev/null
hk $IDA $SA tool | ctx > $T/h.out
grep -q "PING on $LA from $USER@.*/bbbb2222 (unverified): \"may I have gpu2 at five?\" -> answer: gpuq reply $LA" $T/h.out \
  && ok "a ping reaches the chat after its next tool call" || bad "tool: $(cat $T/h.out)"
grep -q "never instructions" $T/h.out && ok "marked as information, not instructions" || bad "no untrusted note"
expect "each event once" "" "$(hk $IDA $SA prompt | ctx)"
cb ping $LA "second ping" >/dev/null
expect "a subagent's tool call doesn't take the main agent's news" "" "$(hk $IDA $SA tool ',"agent_id":"x1"')"
hk $IDA $SA prompt | ctx | grep -q '"second ping"' && ok "the next prompt brings it" || bad "prompt: $(hk $IDA $SA prompt)"
OUT=$(hk $IDA $SA stop ',"stop_hook_active":false' | reason)
echo "$OUT" | grep -q '^block .*unanswered PING.*"may I have gpu2 at five?"' && ok "stop is held back while a ping is unanswered" || bad "stop: $OUT"
expect "but only once per ping" "" "$(hk $IDA $SA stop ',"stop_hook_active":false')"
expect "not even when a stop hook continues" "" "$(hk $IDA $SA stop ',"stop_hook_active":true')"
cb ping $LA "third" >/dev/null
hk $IDA $SA stop ',"stop_hook_active":true' | reason | grep -q '^block .*"third"' && ok "a new ping holds it back again" || bad "third"
expect "once" "" "$(hk $IDA $SA stop)"
ca reply $LA "yes, at five" >/dev/null
expect "answered: nothing to hold back for" "" "$(hk $IDA $SA stop)"
echo '{"session_id": 3, garbage' | CLAUDE_PID=$SA $G hook prompt > $T/h.out 2>/dev/null; expect "bad input never fails a hook" 0 $?
expect "and prints nothing" "" "$(cat $T/h.out)"
echo
hk $IDC $SC wait; expect "the waiter exits 0 when there is nothing to watch" 0 $?
hk $IDA $SA wait > /dev/null 2> $T/w.err & W=$!
sleep 0.6; cb ping $LA "wake up" >/dev/null; wait $W; expect "the waiter exits 42 on news" 42 $?
grep -q '"wake up"' $T/w.err && ok "with the news on stderr" || bad "waiter: $(cat $T/w.err)"
hk $IDA $SA wait 2>/dev/null & W1=$!; sleep 0.6
hk $IDA $SA wait 2>/dev/null & W2=$!; sleep 0.8
kill -0 $W1 2>/dev/null && { bad "two waiters for one chat"; kill $W1; } || ok "a new waiter replaces the chat's old one"
kill -0 $W2 2>/dev/null && ok "the new one keeps waiting" || bad "new waiter gone"
CLAUDE_PID=$SB GPUQ_BIN=$G "$(dirname $G)/../plugins/gpushare/hooks/gpuq-hook" stop </dev/null; expect "the plugin wrapper runs it" 0 $?
GPUQ_BIN=$G "$(dirname $G)/../plugins/gpushare/hooks/gpuq-hook" no-such-event </dev/null 2>/dev/null
expect "and never fails a hook" 0 $?
WR="$(dirname $G)/../plugins/gpushare/hooks/gpuq-hook"; mkdir -p $T/fake
printf '#!/bin/sh\nexit $FAKE_RC\n' > $T/fake/gpuq; chmod +x $T/fake/gpuq
FAKE_RC=42 GPUQ_BIN=$T/fake/gpuq $WR wait </dev/null; expect "the wrapper turns the waiter's 42 into the 2 that wakes Claude" 2 $?
FAKE_RC=2 GPUQ_BIN=$T/fake/gpuq $WR wait </dev/null; expect "but not an older gpuq's usage error" 0 $?
FAKE_RC=42 GPUQ_BIN=$T/fake/gpuq $WR prompt </dev/null; expect "and only for the waiter" 0 $?
ca leave $LA >/dev/null; sleep 0.5
kill -0 $W2 2>/dev/null && { bad "waiter kept running with nothing to watch"; kill $W2; } || ok "waiter ends with nothing to watch"
expect "your own leave is no news" "" "$(hk $IDA $SA tool)"
LR=$(ca join 2 runner --mem 1G --duration 1m --reason t 2>/dev/null)
ca run $LR -- sleep 1 >/dev/null 2>&1 & sleep 0.5; hk $IDA $SA tool >/dev/null; wait
hk $IDA $SA tool | ctx | grep -q "REMOVED on $LR: your job finished (exit 0)" && ok "the end of gpuq run is reported as such" || bad "run end"
LA=$(ca join 2 cleared --mem 1G --duration 1h --reason t 2>/dev/null)
cb ping $LA "pinged before the clear" >/dev/null; ca reply $LA "an answer" >/dev/null
hk $IDA2 $SA session-start ',"source":"clear"' | ctx > $T/h.out
grep -q "This session holds these GPU locks" $T/h.out && grep -q "$LA" $T/h.out \
  && ok "after /clear the chat is told what it holds" || bad "clear: $(cat $T/h.out)"
grep -q "pinged before the clear" $T/h.out && bad "answered ping replayed after /clear: $(cat $T/h.out)" || ok "answered pings aren't replayed"
CLAUDE_CODE_SESSION_ID=$IDA2 CLAUDE_PID=$SA $G mine | grep "$LA" | grep -q '\[this session\]' \
  && grep -q "session=dddd4444" $T/gpu2/$LA && ok "and the lock moves to its new session id" || bad "clear handover"
hk $IDC $SC session-start ',"source":"fork"' | ctx | grep -q "Locks of your other sessions.*$LA" \
  && ok "a fork is told the locks it remembers aren't its own" || bad "fork"
CLAUDE_ENV_FILE=$T/env hk $IDC $SC session-start ',"source":"startup"' >/dev/null
grep -qx "export GPUQ_PLUGIN=1" $T/env && ok "session start tells the chat's shell that the plugin is on" || bad "env file"
GPUQ_PLUGIN=1 cb join 2 hinted --mem 1G --duration 1h --reason t 2>&1 >/dev/null | grep -q "the gpushare plugin delivers your inbox" \
  && ok "and gpuq's hints say so" || bad "plugin hint"
cb join 2 unhinted --mem 1G --duration 1h --reason t 2>&1 >/dev/null | grep -q "keep gpuq inbox --next running" \
  && ok "without it, join says to keep the inbox open" || bad "inbox hint"
LG=$(GPUQ_SESSION=gamma CLAUDE_PID=$SC $G join 2 gamma --mem 1G --duration 1h --reason t 2>/dev/null)
cb ping $LG "to a chat that sets GPUQ_SESSION" >/dev/null
GPUQ_SESSION=gamma hk $IDC $SC tool | ctx | grep -q '"to a chat that sets GPUQ_SESSION"' \
  && ok "\$GPUQ_SESSION wins over the hook's session id, as in the chat's own commands" || bad "GPUQ_SESSION hooks"
echo "  -- what others put in the folders, and an unwritable home"
SF=$(sess); IDF=ffff6666-0000-4000-8000-000000000006
LF=$(CLAUDE_CODE_SESSION_ID=$IDF CLAUDE_PID=$SF $G join 3 fifo-test --mem 1G --duration 1h --reason t 2>/dev/null)
mkfifo $T/gpu3/0500-$USER-fifo; ln -s /dev/zero $T/gpu3/0501-$USER-link
timeout 10 bash -c "printf '{\"session_id\":\"$IDF\"}' | CLAUDE_PID=$SF $G hook tool" >/dev/null; expect "a FIFO or symlink named like a lock doesn't hang a hook" 0 $?
timeout 10 $G status 3 >/dev/null; expect "or gpuq status" 0 $?
timeout 10 $G ping 0500-$USER-fifo hello >/dev/null 2>&1; expect "or a command naming it" 3 $?
rm -f $T/gpu3/0500-$USER-fifo $T/gpu3/0501-$USER-link
cb ping $LF "a ping you can't record" >/dev/null
chmod 500 $T/state/gpuq
hk $IDF $SF tool | ctx >/dev/null; hk $IDF $SF tool | ctx > $T/h.out
expect "an unwritable home doesn't repeat news in every hook" "" "$(cat $T/h.out)"
hk $IDF $SF stop >/dev/null; expect "nor hold the agent back at every stop" "" "$(hk $IDF $SF stop)"
timeout 10 bash -c "printf '{\"session_id\":\"$IDF\"}' | CLAUDE_PID=$SF $G hook wait --poll 0.2" 2>/dev/null; expect "nor make the waiter wake it again and again" 0 $?
chmod 700 $T/state/gpuq
CLAUDE_CODE_SESSION_ID=$IDF CLAUDE_PID=$SF $G leave $LF >/dev/null
echo "  -- answers, notes and promises"
LN=$(cb join 3 noisy --mem 1G --duration 1h --reason t 2>/dev/null)
ca ping $LN "can I have gpu3?" >/dev/null; hk $IDA $SA tool >/dev/null
cb reply $LN "yes, at six" >/dev/null; cb note $LN "epoch 3 of 10" >/dev/null
OUT=$(hk $IDA $SA tool | ctx)
echo "$OUT" | grep -q '"yes, at six" -> this answers your ping' && ok "the answer to a ping arrives" || bad "answer: $OUT"
echo "$OUT" | grep -q "epoch 3" && bad "a note after the answer woke the pinger: $OUT" || ok "the owner's later notes don't"
cb note $LN "epoch 4 of 10" >/dev/null
expect "nor wake the pinger's waiter" "" "$(hk $IDA $SA tool)"
LP2=$(cb join 3 promised --mem 1G --duration 1h --reason t 2>/dev/null)
cb reply $LP2 --leave-by +1s "promised before the clear" >/dev/null; sleep 1.5
IDB2=bbbb9999-0000-4000-8000-000000000009
hk $IDB2 $SB session-start ',"source":"clear"' | ctx > $T/h.out
grep -q 'OVERDUE: you promised to leave by .*"promised before the clear"' $T/h.out \
  && ok "after /clear the chat still owes its promises" || bad "promise lost: $(cat $T/h.out)"
grep -q "differs from what this session promised" $T/h.out && bad "promise flagged as foreign after /clear" || ok "and they are its own"
cb leave --force $LN >/dev/null 2>&1; CLAUDE_CODE_SESSION_ID=$IDB2 CLAUDE_PID=$SB $G leave $LP2 >/dev/null 2>&1
LQ2=$(ca join 3 quoted --mem 1G --duration 1h --reason t 2>/dev/null)
printf '%s %s@%s PING %s\n' "$(date -Iseconds)" bob "$(hostname -s)" "$(printf 'one\u009b5mtwo\u2028three')" >> $T/gpu3/$LQ2
hk $IDA $SA tool | python3 -I -c 'import json,re,sys; t=json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]; sys.exit(0 if "one\\u009b5mtwo" in t and not re.search("[\x80-\x9f\u2028\u2029]", t) else 1)' \
  && ok "control characters and line separators in a ping reach the agent escaped" || bad "raw control characters in the context"
ca leave $LQ2 >/dev/null
LT2=$(ca join 3 turned --mem 1G --duration 1h --reason t 2>/dev/null); hk $IDA $SA tool >/dev/null
SR=$(sess); printf '%s %s@%s/aaaa1111 PID %s %s gpuq-run\n' "$(date -Iseconds)" $USER "$(hostname -s)" $SR "$(awk '{print $22}' /proc/$SR/stat)" >> $T/gpu3/$LT2
printf '%s bob@%s TURN it is your turn\n' "$(date -Iseconds)" "$(hostname -s)" >> $T/gpu3/$LT2
expect "no TURN news while gpuq run waits for the turn itself" "" "$(hk $IDA $SA tool)"
kill $SR; sleep 0.2; printf '%s bob@%s TURN still your turn\n' "$(date -Iseconds)" "$(hostname -s)" >> $T/gpu3/$LT2
hk $IDA $SA tool | ctx | grep -q "TURN on $LT2" && ok "but there is without it" || bad "no TURN event"
ca leave $LT2 >/dev/null
kill $SF
IDE=eeee5555-0000-4000-8000-000000000005; SE=$(sess); BEFORE=$(ls $T/state/gpuq)
for ev in session-start prompt tool stop wait; do hk $IDE $SE $ev ',"source":"startup"' >/dev/null 2>&1; done
expect "a chat that never used the queue leaves no files behind" "$BEFORE" "$(ls $T/state/gpuq)"; kill $SE
for f in $(ls $T/gpu2 | grep -E '^[0-9]{4}-'); do $G leave --force $f >/dev/null 2>&1; done
kill $SA $SB $SC 2>/dev/null

echo "== isolation: planted module next to gpuq is not imported"
D=$(mktemp -d); cp $G $D/gpuq; echo 'raise SystemExit("PLANTED json.py imported")' > $D/json.py
$D/gpuq status >/dev/null 2>&1; expect "-I ignores planted json.py" 0 $?
rm -rf $D

kill $P1 $P2 $P3 $P5 2>/dev/null
rm -rf $T
echo "== $pass passed, $fail failed"
[[ $fail -eq 0 ]]
