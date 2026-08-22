#!/bin/bash
# Speculative-decoding spec-type sweep. Written 2026-08-22.
#
# WHY NOT n-max: --spec-draft-n-max is a NO-OP with --spec-type draft-mtp on this model.
# Measured per-request (speculative.n_max = 1, 2, 6): draft tokens per output token stayed
# at 0.74-0.77 in all three. Qwen3.6's MTP head emits one draft token per step regardless,
# so the cap is not the binding constraint. The spec TYPE is.
#
# spec-type is a startup flag, so each arm needs its own server. Only ONE large model may be
# resident at a time on this box (two copies OOM it and have killed the desktop before), so
# arms run strictly serially with a full teardown between them, polling until the process is
# actually gone rather than sleeping a fixed amount.
#
# llama-test.service is stopped for the duration and restarted at the end. Its unit file is
# NOT modified. The test servers use a scratch cache dir so the live prompt cache is untouched.
set -u
OUT="$1"; ROUNDS="${2:-3}"
BIN=/home/jstormes/code/llama.cpp-458/build/bin/llama-server
D=/sys/class/drm/card1/device
HW=$(echo $D/hwmon/hwmon*)
SCRATCH=$(mktemp -d /tmp/claude-1000/-home-jstormes/*/scratchpad/specbench.XXXXXX 2>/dev/null || mktemp -d)

export VK_ICD_FILENAMES=/opt/llama/strix-toolbox/vulkan/driver/radeon_icd.x86_64.json
export VK_DRIVER_FILES=$VK_ICD_FILENAMES
export LD_LIBRARY_PATH=/opt/llama/strix-toolbox/vulkan/driver:/home/jstormes/code/llama.cpp-458/build/bin
export GGML_VK_MMID_ROWLISTS=1 GGML_VK_MMID_SMALLN=1 GGML_VK_MMID_BM64=1
export GGML_VK_MMID_WAVE32=1 GGML_VK_MMID_F16B=1 GGML_VK_MMID_M128=1
export GGML_VK_FA_WAVE32=1

{
  echo "# run: $(date -Is)"
  echo "# cmdline: $(cat /proc/cmdline)"
  echo "# iommu_groups: $(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)"
  echo "# vram_total_MiB: $(( $(cat $D/mem_info_vram_total)/1024/1024 ))  gtt_total_MiB: $(( $(cat $D/mem_info_gtt_total)/1024/1024 ))"
  echo "# mem_total_kB: $(awk '/MemTotal/{print $2}' /proc/meminfo)"
  echo "# dpm: $(cat $D/power_dpm_force_performance_level)  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)  platform_profile: $(cat /sys/firmware/acpi/platform_profile)"
  echo "# bios: $(cat /sys/class/dmi/id/bios_version)  product: $(cat /sys/class/dmi/id/product_version)"
} >> "$OUT"

wait_gone() {
  for i in $(seq 1 120); do pgrep -x llama-server >/dev/null || return 0; sleep 1; done
  echo "FATAL: llama-server did not exit" >&2; exit 1
}

start_server() {   # $1 = spec-type arm
  local SPEC="$1" EXTRA=""
  [ "$SPEC" != "none" ] && EXTRA="--spec-draft-type-k q8_0 --spec-draft-type-v q8_0"
  rm -rf "$SCRATCH/pcache"; mkdir -p "$SCRATCH/pcache"
  $BIN --host 127.0.0.1 --port 8080 \
    -m /models/Qwen3.6-35B-A3B-Q8_0.gguf -a Qwen3.6-35B-A3B \
    --mmproj /models/mmproj-BF16.gguf \
    -ngl 999 --fit off --no-mmap --cache-ram 8192 \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    -c 262144 -b 8192 -ub 1024 -np 1 -fa 1 -kvu \
    --spec-type "$SPEC" $EXTRA \
    --jinja --reasoning-budget 2048 \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
    -dev Vulkan0 > "$SCRATCH/server.log" 2>&1 &
  for i in $(seq 1 180); do
    curl -sf -m 2 http://127.0.0.1:8080/health >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "FATAL: server ($SPEC) did not become ready; tail:" >&2
  tail -20 "$SCRATCH/server.log" >&2; exit 1
}

stop_server() { pkill -x llama-server 2>/dev/null; wait_gone; }

sample() {
  while :; do
    s=$(grep '\*' $D/pp_dpm_sclk 2>/dev/null | awk '{print $2}' | tr -dc '0-9')
    b=$(cat $D/gpu_busy_percent 2>/dev/null); p=$(cat $HW/power1_average 2>/dev/null)
    echo "$s $b $p" >> "$1"; sleep 1
  done
}

run_one() {
  local ARM="$1" IDX="$2"
  local TEL="$SCRATCH/tel"; : > "$TEL"
  sample "$TEL" & local SP=$!
  NONCE=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  python3 - "$NONCE" > "$SCRATCH/req.json" <<'PY'
import json,sys
head=f"// session {sys.argv[1]}\n"
body="void f(int x){ return x+1; }\n"*1500
print(json.dumps({"messages":[{"role":"user","content":head+body+"\n\nSummarize the code above in three sentences."}],
                  "max_tokens":400,"stream":False,"temperature":0.7}))
PY
  RESP=$(curl -s -m 1800 http://127.0.0.1:8080/v1/chat/completions \
         -H 'Content-Type: application/json' --data @"$SCRATCH/req.json")
  kill $SP 2>/dev/null; wait $SP 2>/dev/null
  echo "$RESP" | ARM="$ARM" IDX="$IDX" TEL="$TEL" python3 -c "
import json,sys,os
d=json.load(sys.stdin); t=d.get('timings',{})
pn=t.get('predicted_n') or 0; dn=t.get('draft_n') or 0; da=t.get('draft_n_accepted') or 0
rows=[l.split() for l in open(os.environ['TEL']) if len(l.split())==3]
rows=[r for r in rows if r[1].isdigit() and int(r[1])>50]
def med(i):
    v=sorted(float(r[i]) for r in rows); return v[len(v)//2] if v else float('nan')
print('%s\t%s\t%s\t%.2f\t%.3f\t%s\t%s\t%s\t%.2f\t%.2f\t%.0f\t%.1f'%(
  os.environ['ARM'],os.environ['IDX'],t.get('prompt_n'),
  t.get('prompt_per_second') or 0,t.get('predicted_per_second') or 0,
  pn,dn,da,(dn/pn) if pn else 0,(100.0*da/dn) if dn else 0,med(0),med(2)/1e6))
" >> "$OUT"
  tail -1 "$OUT"
}

ARMS="none draft-mtp ngram-cache ngram-map-k"
systemctl --user stop llama-test.service llama.service 2>/dev/null
wait_gone
for r in $(seq 1 "$ROUNDS"); do
  for A in $ARMS; do
    start_server "$A"
    run_one "$A" "$r"
    stop_server
  done
done
rm -rf "$SCRATCH"
systemctl --user start llama-test.service
echo "=== restored llama-test.service: $(systemctl --user is-active llama-test.service) ==="
