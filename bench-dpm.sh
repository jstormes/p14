#!/bin/bash
# Interleaved DPM {auto,high} benchmark with per-run GPU telemetry.
# Derived from bench-p16.sh, but the governor arm is dropped (closed 2026-08-21,
# worth ~0%) so the same wall-clock buys more reps on the one live variable.
# Prompt shape identical to bench-local.sh: 1500x code line + nonce => ~18k tok.
set -u
OUT="$1"; ROUNDS="${2:-4}"; FIFO="$3"
D=/sys/class/drm/card1/device
HW=$(echo $D/hwmon/hwmon*)

apply() { echo "$1" > "$FIFO"; }

sample() {
  while :; do
    s=$(grep '\*' $D/pp_dpm_sclk 2>/dev/null | awk '{print $2}' | tr -dc '0-9')
    b=$(cat $D/gpu_busy_percent 2>/dev/null)
    p=$(cat $HW/power1_average 2>/dev/null)
    t=$(cat $HW/temp1_input 2>/dev/null)
    echo "$s $b $p $t" >> "$1"
    sleep 1
  done
}

run_one() {
  local ARM="$1" IDX="$2"
  local TEL=/tmp/tel.$$; : > "$TEL"
  sample "$TEL" & local SP=$!
  NONCE=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  python3 - "$NONCE" > /tmp/bvd.json <<'PY'
import json,sys
head=f"// session {sys.argv[1]}\n"
body="void f(int x){ return x+1; }\n"*1500
print(json.dumps({"messages":[{"role":"user","content":head+body+"\n\nSummarize the code above in three sentences."}],
                  "max_tokens":300,"stream":False,"temperature":0.7}))
PY
  RESP=$(curl -s -m 1800 "http://127.0.0.1:8080/v1/chat/completions" \
         -H "Content-Type: application/json" --data @/tmp/bvd.json)
  kill $SP 2>/dev/null; wait $SP 2>/dev/null
  echo "$RESP" | ARM="$ARM" IDX="$IDX" TEL="$TEL" python3 -c "
import json,sys,os
d=json.load(sys.stdin); t=d.get('timings',{})
dn,da=t.get('draft_n') or 0,t.get('draft_n_accepted') or 0
rows=[l.split() for l in open(os.environ['TEL']) if len(l.split())==4]
rows=[r for r in rows if r[1].isdigit() and int(r[1])>50]
def med(i):
    v=sorted(float(r[i]) for r in rows)
    return v[len(v)//2] if v else float('nan')
print('%s\t%s\t%s\t%s\t%.2f\t%.3f\t%.2f\t%.0f\t%.0f\t%.1f\t%.1f'%(
  os.environ['ARM'],os.environ['IDX'],t.get('prompt_n'),t.get('cache_n'),
  t.get('prompt_per_second') or 0,t.get('predicted_per_second') or 0,
  (100.0*da/dn) if dn else float('nan'),
  med(0),med(1),med(2)/1e6,med(3)/1e3))
" >> "$OUT"
  rm -f "$TEL"
  tail -1 "$OUT"
}

for r in $(seq 1 "$ROUNDS"); do
  for DPM in auto high; do
    apply "dpm:$DPM"; sleep 4
    GOT_D=$(cat $D/power_dpm_force_performance_level)
    [ "$GOT_D" = "$DPM" ] || { echo "STATE MISMATCH want $DPM got $GOT_D" >&2; exit 1; }
    run_one "dpm-$DPM" "$r"
  done
done
