#!/usr/bin/env bash
# Seed llama-server's slots from disk snapshots after it starts, so the first
# Qwen Code launch after a login does not pay a cold ~80 s prefill.
#
# Wired into llama.service as:
#     ExecStartPost=-%h/p14/llama-slot-restore.sh
#
# The leading '-' and the unconditional 'exit 0' at the end are both load
# bearing. A stale or shape-mismatched snapshot must never fail the unit, or
# Restart=on-failure turns a cold cache into a restart loop. Worst case here is
# that the restore is skipped and the first prefill runs cold — exactly the
# behaviour before this script existed.
#
# Snapshots are written by llama-slot-save.sh.
set -uo pipefail

HOST=${LLAMA_HOST:-http://127.0.0.1:8080}
SLOT_DIR=${LLAMA_SLOT_DIR:-$HOME/.local/state/llama-slots}

# One entry per slot to seed. There are only -np 2 slots, and restore targets a
# slot directly, so this list is capped at 2. Add a second project's snapshot
# here if the cross-project cached-token count ever proves disappointing.
SNAPSHOTS=(qwen-boot.bin)
MAX_SLOTS=2

# Model load takes ~10 s from page cache and considerably longer cold. Mirror
# the GPU-wait loop in the unit's ExecStartPre rather than guessing a delay.
for _ in $(seq 1 90); do
  if curl -sf --max-time 2 -o /dev/null "$HOST/health"; then
    break
  fi
  sleep 1
done

if ! curl -sf --max-time 2 -o /dev/null "$HOST/health"; then
  echo "slot-restore: server not healthy after 90s, skipping restore" >&2
  exit 0
fi

slot=0
for snap in "${SNAPSHOTS[@]}"; do
  if [ "$slot" -ge "$MAX_SLOTS" ]; then
    echo "slot-restore: more snapshots than slots, skipping the rest" >&2
    break
  fi

  # Absent snapshot is the normal state on the very first start after install.
  if [ ! -f "$SLOT_DIR/$snap" ]; then
    echo "slot-restore: $snap not present, nothing to seed into slot $slot"
    slot=$((slot + 1))
    continue
  fi

  resp=$(curl -sf --max-time 300 -X POST "$HOST/slots/$slot?action=restore" \
    -H 'Content-Type: application/json' \
    -d "{\"filename\": \"$snap\"}" 2>/dev/null)

  if [ -z "$resp" ]; then
    echo "slot-restore: restore of $snap into slot $slot failed — first prefill will run cold" >&2
  else
    printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("slot-restore:", sys.stdin.read()); sys.exit()
print("slot-restore: restored n_restored =", d.get("n_restored"), "timings =", d.get("timings"))
' 2>/dev/null || echo "slot-restore: restored $snap into slot $slot"
  fi

  slot=$((slot + 1))
done

exit 0
