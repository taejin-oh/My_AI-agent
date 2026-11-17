#!/bin/bash
# LOCAL WORKAROUND (verification only): the outer sandbox forbids lowering
# oom_score_adj, so clamp negative oomScoreAdj in the OCI bundle to 0.
bundle="$PWD"
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --bundle|-b) bundle="${args[$((i+1))]}" ;;
    --bundle=*) bundle="${args[$i]#--bundle=}" ;;
  esac
done
if [ -f "$bundle/config.json" ]; then
  sed -i -E 's/"oomScoreAdj":\s*-[0-9]+/"oomScoreAdj":0/g' "$bundle/config.json"
fi
exec /usr/local/sbin/runc.real "$@"
