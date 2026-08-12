#!/bin/bash
# Reapply the AMD GPU DPM setting that llama.cpp throughput depends on.
#
# power_dpm_force_performance_level defaults to "auto", which lets the GPU sit at
# ~1150 MHz / 13 W under full inference load instead of 2900 MHz / ~55 W. That costs
# roughly 45% of prefill throughput -- see README.md.
#
# This is a RUNTIME write. It does not survive a reboot. Run it after boot, or persist
# it properly (see "Making it persistent" below).
#
# Usage:  sudo ~/p14/set-dpm-high.sh [high|auto|low]
set -eu

LEVEL="${1:-high}"

case "$LEVEL" in
    high|auto|low) ;;
    *) echo "usage: $0 [high|auto|low]" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (sysfs write)" >&2
    echo "  sudo $0 $LEVEL" >&2
    exit 1
fi

found=0
for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    [ -w "$f" ] || continue
    printf '%s\n' "$LEVEL" > "$f"
    echo "$f -> $(cat "$f")"
    found=1
done

if [ "$found" -eq 0 ]; then
    echo "error: no writable power_dpm_force_performance_level found" >&2
    exit 1
fi

# Show the effect. sclk stays pinned at max even at idle when LEVEL=high.
for f in /sys/class/drm/card*/device/pp_dpm_sclk; do
    [ -r "$f" ] || continue
    echo "current sclk: $(grep '\*' "$f" | awk '{print $2}')"
done

# ---------------------------------------------------------------------------
# Making it persistent
#
# The documented install (P14S-NATIVE-INSTALL.md sec9b) persists this with a system
# unit, cpu-performance.service, which also sets the CPU governor. That unit is NOT
# installed on p14 -- llama.service here is a *user* unit tied to the graphical
# session, so the system-unit ordering in the doc does not apply.
#
# If you want it persistent, the least invasive option is a udev rule that fires when
# the amdgpu device appears:
#
#   /etc/udev/rules.d/90-amdgpu-dpm.rules
#     ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", \
#       DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"
#
# Note that "high" also pins the GPU clock at 2900 MHz *at idle*, raising idle power.
# On battery that is a real cost -- which is why this is left manual by default.
# ---------------------------------------------------------------------------
