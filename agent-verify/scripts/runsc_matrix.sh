#!/bin/bash
# Full measurement matrix. Output: ~/agent-verify/measure/runsc/
set -u
G=/root/agent-verify/gvisor; S=/root/agent-verify/scripts; OUT=/root/agent-verify/measure/runsc; mkdir -p $OUT
RUNSC="$G/runsc --root=$G/state --network=none --platform=systrap"
echo "matrix start $(date -u +%FT%TZ)" > $OUT/meta.txt
S_TIME_FORMAT=ISO iostat -dxy 1 1800 vda > $OUT/iostat.txt 2>&1 & IOP=$!
pidstat -d -l 1 1800 2>&1 | grep --line-buffered -E "runsc|memhold|gofer|sentry|Average|^[0-9T:-]+ +UID" > $OUT/pidstat.txt & PP=$!
log() { echo "$(date -u +%FT%T.%3NZ) $*" | tee -a $OUT/events.txt; }
# A) size sweep, compressible content, 3 repeats
for mem in 64 256 512 1024; do for r in 1 2 3; do
  log "BEGIN size mem=$mem rep=$r"
  $S/runsc_cr.sh s${mem}_$r $mem 0 c 2>&1 | grep RESULT | tee -a $OUT/results.txt
  log "END size mem=$mem rep=$r"; sleep 2
done; done
# B) incompressible content 256MiB x2
for r in 1 2; do log "BEGIN rand mem=256 rep=$r"; $S/runsc_cr.sh rnd256_$r 256 0 r 2>&1 | grep RESULT | tee -a $OUT/results.txt; log "END rand"; sleep 2; done
# C) memory reclaim check with 1024MiB: measure host free before/after checkpoint
log "BEGIN reclaim mem=1024"
B=$G/bundles/rec; IMG=$G/images/rec; mkdir -p $B $IMG; rm -rf $B/rootfs; mkdir -p $B/rootfs; cp -a $G/rootfs/. $B/rootfs/
(cd $B && rm -f config.json && $G/runsc spec -- /bin/memhold 1024 0 c >/dev/null && sed -i 's/"readonly": true/"readonly": false/' config.json)
$RUNSC delete -force rec >/dev/null 2>&1; rm -rf $IMG/*
M0=$(free -m | awk 'NR==2{print $3" "$7}'); $RUNSC run -detach --bundle $B rec; sleep 6
M1=$(free -m | awk 'NR==2{print $3" "$7}'); $RUNSC checkpoint --image-path=$IMG rec; sleep 3
M2=$(free -m | awk 'NR==2{print $3" "$7}'); $RUNSC delete -force rec >/dev/null 2>&1; sync; sleep 2
M3=$(free -m | awk 'NR==2{print $3" "$7}')
log "RECLAIM used/avail MiB: before_run=$M0 running=$M1 after_checkpoint=$M2 after_delete=$M3"
echo "RECLAIM before_run=$M0 running=$M1 after_checkpoint=$M2 after_delete=$M3" >> $OUT/results.txt
# D) concurrency: N x 256MiB checkpointed at the same moment
for N in 4 8; do
  log "BEGIN concurrent N=$N mem=256"
  ids=""; for i in $(seq 1 $N); do id=c${N}_$i; ids="$ids $id"; B=$G/bundles/$id; mkdir -p $B; rm -rf $B/rootfs; mkdir -p $B/rootfs; cp -a $G/rootfs/. $B/rootfs/
    (cd $B && rm -f config.json && $G/runsc spec -- /bin/memhold 256 0 c >/dev/null && sed -i 's/"readonly": true/"readonly": false/' config.json)
    $RUNSC delete -force $id >/dev/null 2>&1; rm -rf $G/images/$id; mkdir -p $G/images/$id
    $RUNSC run -detach --bundle $B $id; done
  sleep 8
  T0=$(date +%s.%N); for id in $ids; do ( t0=$(date +%s.%N); $RUNSC checkpoint --image-path=$G/images/$id $id; echo "$id ckpt_s=$(echo "$(date +%s.%N) - $t0" | bc)" >> $OUT/conc_${N}.txt ) & done; wait; T1=$(date +%s.%N)
  log "concurrent N=$N all_ckpt_wall_s=$(echo "$T1 - $T0" | bc)"; echo "CONCURRENT N=$N wall_s=$(echo "$T1 - $T0" | bc) per: $(tr '\n' ' ' < $OUT/conc_${N}.txt)" >> $OUT/results.txt
  for id in $ids; do $RUNSC delete -force $id >/dev/null 2>&1; done; sleep 3
  # sequential baseline for same N
  T0=$(date +%s.%N); for id in $ids; do B=$G/bundles/$id; rm -rf $G/images/$id; mkdir -p $G/images/$id; $RUNSC run -detach --bundle $B $id; done; sleep 8
  T0=$(date +%s.%N); for id in $ids; do $RUNSC checkpoint --image-path=$G/images/$id $id; done; T1=$(date +%s.%N)
  log "sequential N=$N all_ckpt_wall_s=$(echo "$T1 - $T0" | bc)"; echo "SEQUENTIAL N=$N wall_s=$(echo "$T1 - $T0" | bc)" >> $OUT/results.txt
  for id in $ids; do $RUNSC delete -force $id >/dev/null 2>&1; done; sleep 3
done
kill $IOP $PP 2>/dev/null; echo "matrix end $(date -u +%FT%TZ)" >> $OUT/meta.txt; log DONE
