#!/bin/bash
set -u
S="$(dirname "$0")"
EP=http://llm3:8080/completion
RES=$S/results-ub.tsv; ST=$S/ub-status
UNIT=/etc/systemd/system/llama-qwen3.6-35b-q8.service
SVC=llama-qwen3.6-35b-q8.service
rm -f $ST
echo -e "block\tub\tub_live\trun\tprompt_n\tpp_tps\ttg_tps" > $RES
BASE=$(python3 -c "print('The quick brown fox jumps over the lazy dog while the engineer benchmarks the inference server carefully. '*450)")

health_wait(){
  for i in $(seq 1 72); do curl -sf -m 3 http://llm3:8080/health >/dev/null 2>&1 && return 0; sleep 5; done
  return 1
}
restore(){
  ssh llm3 "sudo cp $UNIT.bak-ubtest-20260902 $UNIT && sudo systemctl daemon-reload && sudo systemctl restart $SVC"
  health_wait || echo "RESTORE-HEALTH-FAIL" >> $ST
}
set_ub(){
  ssh llm3 "sudo sed -i 's/-ub [0-9]\+/-ub $1/' $UNIT && sudo systemctl daemon-reload && sudo systemctl restart $SVC"
  if ! health_wait; then echo "FAIL health after -ub $1" >> $ST; restore; exit 1; fi
  UB_LIVE=$(ssh llm3 "ps -eo args | grep -o '\-ub [0-9]*' | head -1" | awk '{print $2}')
}
run_one(){ # $1=block $2=ub $3=run  (discard if run=w)
  local TAG=$(openssl rand -hex 8)
  python3 - "$EP" "$TAG $BASE" "$1" "$2" "$UB_LIVE" "$3" "$RES" <<'PY'
import json,sys,urllib.request
ep,prompt,blk,ub,ublive,run,res=sys.argv[1:8]
req=urllib.request.Request(ep,data=json.dumps({"prompt":prompt,"n_predict":256,"cache_prompt":False,"ignore_eos":True}).encode(),headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req,timeout=600))
t=d["timings"]
if run!="w":
    open(res,"a").write(f'{blk}\t{ub}\t{ublive}\t{run}\t{t["prompt_n"]}\t{t["prompt_per_second"]:.2f}\t{t["predicted_per_second"]:.2f}\n')
PY
}

BLK=0
for UB in 2048 1024 1024 2048; do
  BLK=$((BLK+1))
  echo "block $BLK: -ub $UB (restarting)"
  set_ub $UB
  echo "block $BLK live ub=$UB_LIVE, warmup"
  run_one $BLK $UB w
  for r in 1 2 3 4 5; do echo "block $BLK run $r"; run_one $BLK $UB $r; done
done
echo "restoring original unit"
restore
echo DONE | tee -a $ST
