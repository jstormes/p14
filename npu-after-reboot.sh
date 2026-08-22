#!/bin/bash
# Post-reboot verification + FLM NPU bring-up. Written 2026-08-21.
#
# Context: the NPU was blocked by TWO things, set together on 2026-08-06:
#   1. /etc/modprobe.d/blacklist-amdxdna.conf   (removed -> /root/blacklist-amdxdna.conf.removed)
#   2. amd_iommu=off on the kernel cmdline      (removed from /etc/default/grub)
# (2) was the real blocker: XDNA2 needs SVA, SVA needs the IOMMU, and with
# amd_iommu=off there were zero IOMMU groups, so amdxdna_drm_open failed -19.
#
# Revert everything:
#   sudo cp /etc/default/grub.bak-claude-20260821 /etc/default/grub && sudo update-grub
#   sudo cp /root/blacklist-amdxdna.conf.removed /etc/modprobe.d/blacklist-amdxdna.conf
#   sudo reboot
set -u
ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; FAILED=1; }
FAILED=0

echo "== 1. kernel cmdline =="
grep -q 'amd_iommu=off' /proc/cmdline && bad "amd_iommu=off still set - did you reboot?" || ok "IOMMU not disabled"
grep -q 'gttsize=49152' /proc/cmdline && ok "GTT params intact" || bad "GTT params MISSING - restore grub backup"

echo "== 2. IOMMU active =="
N=$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)
[ "$N" -gt 0 ] && ok "$N IOMMU groups" || bad "still 0 IOMMU groups"

echo "== 3. amdxdna driver =="
grep -q amdxdna /proc/modules && ok "module loaded" || bad "module not loaded (modprobe amdxdna)"
[ -e /dev/accel/accel0 ] && ok "/dev/accel/accel0 present" || bad "no /dev/accel/accel0"
echo "     firmware: $(cat /sys/class/accel/accel0/device/fw_version 2>/dev/null) (need >= 1.1.0.0)"

echo "== 4. XRT can open the device  <-- this is the one that failed before =="
if timeout 60 xrt-smi examine 2>&1 | grep -qi 'error'; then
  bad "xrt-smi still errors:"; timeout 60 xrt-smi examine 2>&1 | grep -i error | sed 's/^/        /'
  echo "        check: dmesg | grep -i xdna"
else
  ok "xrt-smi opened the NPU"; timeout 60 xrt-smi examine 2>&1 | sed -n '5,14p' | sed 's/^/        /'
fi

echo "== 5. GPU stack unaffected by IOMMU being back on =="
echo "     GTT total: $(awk '{printf "%.0f GiB\n",$1/1073741824}' /sys/class/drm/card1/device/mem_info_gtt_total 2>/dev/null)  (expect 48)"
systemctl --user is-active llama-test.service >/dev/null 2>&1 && ok "llama-test.service running" || echo "  NOTE  llama-test.service not running (start it and re-check throughput)"

echo
if [ "$FAILED" -ne 0 ]; then echo "NOT READY - fix the FAILs above."; exit 1; fi
echo "All checks passed. Now install the FLM backend:"
echo "  lemonade-server backends install flm:npu"
echo "  lemonade-server pull <an FLM model>     # FLM uses its own model format, not your GGUF"
echo "  lemonade-server load <model> && lemonade-server status"
echo
echo "Then benchmark against the GPU baseline (llama.cpp tuned = 459 PP / ~16-22 TG):"
echo "  <scratchpad>/bench-any.sh http://127.0.0.1:13305/api/v1/chat/completions <model> NPU-flm 3 out.tsv"
echo "  NOTE: interleave arms with a cooldown - this box saturates at 99C and"
echo "        sequential A/B is worth ~25% PP / ~40% TG of drift. See lemonade-on-gfx1150 memory."
