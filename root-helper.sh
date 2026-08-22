#!/bin/sh
# Long-lived root helper. Reads "dpm:<lvl>" / "gov:<name>" / "quit" from a FIFO
# and applies them. Exists so the whole benchmark needs exactly one sudo dialog.
#
# TWO TRAPS, both hit on 2026-08-22 and both fail as a silent hang rather than an
# error -- the helper dies, and the benchmark then blocks forever on its first
# write to a FIFO that no longer has a reader.
#
#   1. DO NOT put the FIFO in /tmp. Ubuntu 26.04 sets fs.protected_fifos=1, which
#      refuses an open of a FIFO in a sticky world-writable directory by anyone
#      who does not own it -- root included. The helper prints
#      "cannot create <fifo>: Permission denied" and exits. Put the FIFO in a
#      normal directory, e.g. ~/p14/.dpm-fifo.
#
#   2. DO NOT wrap the "sudo -n root-helper.sh" launch in setsid (or anything else
#      that starts a new session). sudo-rs keys its auth timestamp by session ID,
#      so a new session cannot see the timestamp the preceding "sudo -A" just
#      created; "sudo -n" fails instantly and silently under a redirect.
#
# After launching the helper, check it is actually alive before benchmarking:
#   sudo -n ./root-helper.sh "$FIFO" &
#   HELPER=$!; sleep 2; kill -0 $HELPER || { echo "helper failed to start"; exit 1; }
F="$1"
exec 3<> "$F"
while read -r L <&3; do
  case "$L" in
    dpm:*) for f in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
             echo "${L#dpm:}" > "$f"; done ;;
    gov:*) for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
             echo "${L#gov:}" > "$f" 2>/dev/null; done ;;
    quit)  exit 0 ;;
  esac
done
