#!/bin/bash
set -u
S="$(dirname "$0")"
EP=http://llm3:8080/completion
RES=$S/results.tsv; SAM=$S/samples.tsv
echo -e "run\tarm\tdpm\tprompt_n\tpp_tps\ttg_tps" > $RES
echo -e "run\tarm\tpower_uW\ttemp_mC" > $SAM
BASE=$(python3 -c "print('The quick brown fox jumps over the lazy dog while the engineer benchmarks the inference server carefully. '*170)")

set_dpm(){ ssh llm3 "echo $1 | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level >/dev/null 2>&1 || for d in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo $1 | sudo tee \$d >/dev/null; done"; }

run_one(){ # $1=run_id $2=arm
  local TAG=$(openssl rand -hex 8)   # fixed 16-char width
  local DPMNOW=$(ssh llm3 'cat /sys/class/drm/card*/device/power_dpm_force_performance_level' | head -1)
  ( sleep 4; for i in 1 2 3 4 5; do
      ssh llm3 'cat /sys/class/drm/card*/device/hwmon/hwmon*/power1_average /sys/class/drm/card*/device/hwmon/hwmon*/temp1_input 2>/dev/null' \
      | paste - - | while read p t; do echo -e "$1\t$2\t$p\t$t" >> $SAM; done
      sleep 3; done ) &
  local SPID=$!
  python3 - "$EP" "$TAG $BASE" "$1" "$2" "$RES" "$DPMNOW" <<'PY'
import json,sys,urllib.request
ep,prompt,rid,arm,res,dpm=sys.argv[1:7]
req=urllib.request.Request(ep,data=json.dumps({"prompt":prompt,"n_predict":256,"cache_prompt":False,"ignore_eos":True}).encode(),headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(req,timeout=300))
t=d["timings"]
open(res,"a").write(f'{rid}\t{arm}\t{dpm}\t{t["prompt_n"]}\t{t["prompt_per_second"]:.2f}\t{t["predicted_per_second"]:.2f}\n')
PY
  wait $SPID 2>/dev/null
}

set_dpm high; sleep 2
echo "warmup (high)"; run_one warmup high; sed -i '/^warmup/d' $RES

for pair in 1 2 3 4 5 6 7 8 9 10; do
  if (( pair % 2 == 1 )); then ORDER="high auto"; else ORDER="auto high"; fi
  for arm in $ORDER; do
    set_dpm $arm; sleep 3
    echo "pair $pair arm $arm"
    run_one "p${pair}" "$arm"
  done
done

set_dpm high
echo DONE
