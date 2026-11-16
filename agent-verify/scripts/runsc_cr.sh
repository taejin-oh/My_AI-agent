#!/bin/bash
# runsc_cr.sh <id> <mem_MiB> <dirty_MiB> [r]   : run -> checkpoint -> restore, print timings & sizes
set -u
G=/root/agent-verify/gvisor; ID=$1; MEM=$2; DIRTY=${3:-0}; MODE=${4:-c}
B=$G/bundles/$ID; IMG=$G/images/$ID; LOG=$G/logs; mkdir -p $B $IMG $LOG
rm -rf $B/rootfs; mkdir -p $B/rootfs
# rootfs per container: bind-mount-free copy would be slow; use a shared read-only lower via overlay? keep simple: hardlink copy
cp -al $G/rootfs/. $B/rootfs/ 2>/dev/null || cp -a $G/rootfs/. $B/rootfs/
cd $B && rm -f config.json && $G/runsc spec -- /bin/memhold $MEM $DIRTY $MODE >/dev/null && sed -i 's/"readonly": true/"readonly": false/' config.json
RUNSC="$G/runsc --root=$G/state --network=none --platform=systrap"
$RUNSC delete -force $ID >/dev/null 2>&1; rm -rf $IMG/*
$RUNSC run -detach --bundle $B $ID >$LOG/$ID.run.log 2>&1 || { echo "run failed"; cat $LOG/$ID.run.log; exit 1; }
# wait until memory is touched and counter ticks
for i in $(seq 1 60); do c=$($RUNSC exec $ID cat /state/counter 2>/dev/null); [ -n "$c" ] && [ "$c" -ge 2 ] && break; sleep 0.5; done
C_BEFORE=$($RUNSC exec $ID cat /state/counter 2>/dev/null)
T0=$(date +%s.%N); $RUNSC checkpoint --image-path=$IMG $ID >$LOG/$ID.ckpt.log 2>&1; RC=$?; T1=$(date +%s.%N)
CK=$(echo "$T1 - $T0" | bc)
SIZE_KB=$(du -sk $IMG | cut -f1); FILES=$(ls -la $IMG | awk 'NR>3{printf "%s=%s ", $NF, $5}')
$RUNSC delete -force $ID >/dev/null 2>&1
T2=$(date +%s.%N); $RUNSC restore -detach --image-path=$IMG --bundle $B $ID >$LOG/$ID.restore.log 2>&1; RC2=$?; T3=$(date +%s.%N)
RS=$(echo "$T3 - $T2" | bc)
sleep 1.5; C_AFTER=$($RUNSC exec $ID cat /state/counter 2>/dev/null)
echo "RESULT id=$ID mem_MiB=$MEM dirty_MiB=$DIRTY mode=$MODE ckpt_rc=$RC ckpt_s=$CK snapshot_kB=$SIZE_KB restore_rc=$RC2 restore_s=$RS counter_before=$C_BEFORE counter_after=$C_AFTER files=[$FILES]"
$RUNSC kill $ID 9 >/dev/null 2>&1; sleep 0.3; $RUNSC delete -force $ID >/dev/null 2>&1
