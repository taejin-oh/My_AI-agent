#!/bin/bash
# Usage: collect.sh <label> <seconds>   -> writes to ~/agent-verify/measure/<label>/
LABEL=$1; DUR=${2:-120}; OUT=~/agent-verify/measure/$LABEL; mkdir -p $OUT
echo "start $(date -u +%FT%TZ)" > $OUT/meta.txt
# 1) disk: whole-VM block device vda (kind node, registry, everything share it)
S_TIME_FORMAT=ISO iostat -dxy 1 $DUR vda > $OUT/iostat.txt 2>&1 &
# 2) processes writing to disk (kB/s), 1s
pidstat -d -l 1 $DUR 2>&1 | grep -v "^$" > $OUT/pidstat.txt &
# 3) per-second: snapshot dir size inside kind node + memory
for ((i=0;i<DUR;i++)); do
  ts=$(date -u +%FT%TZ)
  snap=$(docker exec kind-control-plane sh -c 'du -sk /var/lib/ate/snapshots 2>/dev/null | cut -f1'); 
  actors=$(docker exec kind-control-plane sh -c 'du -sk /var/lib/ate/actors 2>/dev/null | cut -f1')
  rust=$(docker exec kind-control-plane sh -c 'du -sk /var/local-path-provisioner 2>/dev/null | cut -f1')
  read -r _ tot used free shared buff avail < <(free -k | sed -n 2p)
  echo "$ts snapshots_kB=$snap actors_kB=$actors localpath_kB=$rust mem_used_kB=$used mem_avail_kB=$avail" >> $OUT/sizes.txt
  sleep 1
done
wait
echo "end $(date -u +%FT%TZ)" >> $OUT/meta.txt
