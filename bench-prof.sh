#!/bin/bash
# platform_profile {balanced,performance} A/B at a FIXED GPU DPM level, interleaved,
# with per-run GPU telemetry. Written 2026-08-22.
#
# Why this exists: README's "Ruled out" table dismissed platform_profile (480 vs 486)
# on the ORIGINAL p14 mainboard, which pulled 55-62 W at DPM high. The REPLACEMENT
# board tops out at ~46 W at the same 2900 MHz and is ~23% slower than the P16s on
# identical software and identical DIMMs. If the new board is power-capped rather than
# clock-limited, platform_profile is the knob that would show it -- so the old
# "ruled out" verdict has to be re-tested rather than inherited.
#
# Profile is switched with powerprofilesctl, NOT a raw sysfs write: power-profiles-daemon
# owns /sys/firmware/acpi/platform_profile and will fight a direct write.
# No root needed here -- set the DPM level before calling this.
set -u
OUT="$1"; ROUNDS="${2:-3}"
D=/sys/class/drm/card1/device
HW=$(echo $D/hwmon/hwmon*)

# --- provenance: record the configuration this run was taken under -------------
# Added 2026-08-22. A missing amd_iommu=off went unnoticed for a day and produced
# three wrong conclusions, including "the replacement mainboard is 23% slower".
# One line in the header would have caught it on the first run. Never remove this.
{
  echo "# run: $(date -Is)"
  echo "# cmdline: $(cat /proc/cmdline)"
  echo "# iommu_groups: $(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)"
  echo "# vram_total_MiB: $(( $(cat $D/mem_info_vram_total)/1024/1024 ))  gtt_total_MiB: $(( $(cat $D/mem_info_gtt_total)/1024/1024 ))"
  echo "# mem_total_kB: $(awk '/MemTotal/{print $2}' /proc/meminfo)"
  echo "# governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)  platform_profile: $(cat /sys/firmware/acpi/platform_profile)"
  echo "# server: $(systemctl --user is-active llama-test.service llama.service | tr '\n' ' ')"
  echo "# bios: $(cat /sys/class/dmi/id/bios_version 2>/dev/null)  product: $(cat /sys/class/dmi/id/product_version 2>/dev/null)"
} >> "$OUT"
# ------------------------------------------------------------------------------

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
  local TEL=/tmp/telp.$$; : > "$TEL"
  sample "$TEL" & local SP=$!
  NONCE=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  python3 - "$NONCE" > /tmp/bvp.json <<'PY'
import json,sys
head=f"// session {sys.argv[1]}\n"
body="void f(int x){ return x+1; }\n"*1500
print(json.dumps({"messages":[{"role":"user","content":head+body+"\n\nSummarize the code above in three sentences."}],
                  "max_tokens":300,"stream":False,"temperature":0.7}))
PY
  RESP=$(curl -s -m 1800 "http://127.0.0.1:8080/v1/chat/completions" \
         -H "Content-Type: application/json" --data @/tmp/bvp.json)
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
  for PROF in balanced performance; do
    powerprofilesctl set "$PROF"
    sleep 5
    GOT=$(cat /sys/firmware/acpi/platform_profile)
    WANT="$PROF"; [ "$PROF" = "power-saver" ] && WANT=low-power
    [ "$GOT" = "$WANT" ] || { echo "PROFILE MISMATCH want $WANT got $GOT" >&2; exit 1; }
    run_one "prof-$PROF" "$r"
  done
done
powerprofilesctl set balanced
