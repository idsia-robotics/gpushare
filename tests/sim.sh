#!/bin/bash
# Simulation tests for gpuq in a scratch root (no real GPUs touched).
# usage: tests/sim.sh bin/gpuq
set -u
G=${1:?path to gpuq}
T=$(mktemp -d "${TMPDIR:-/tmp}/gpuqsim.XXXX")
export GPUQ_ROOT=$T GPUQ_NO_SMI=1
unset CLAUDE_PID
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

echo "== isolation: planted module next to gpuq is not imported"
D=$(mktemp -d); cp $G $D/gpuq; echo 'raise SystemExit("PLANTED json.py imported")' > $D/json.py
$D/gpuq status >/dev/null 2>&1; expect "-I ignores planted json.py" 0 $?
rm -rf $D

kill $P1 $P2 $P3 $P5 2>/dev/null
rm -rf $T
echo "== $pass passed, $fail failed"
[[ $fail -eq 0 ]]
