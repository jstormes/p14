#!/usr/bin/env bash
# Snapshot a warm llama-server slot to disk so llama-slot-restore.sh can seed it
# back after a restart.
#
# The point of this is Qwen Code's opening payload: ~34.5k tokens of system
# prompt plus tool schemas, which costs ~80 s of GPU prefill from cold. The
# in-RAM prompt cache (--cache-ram) already covers repeat turns, but it dies
# with the process, and llama.service is PartOf=graphical-session.target so it
# restarts at every login.
#
# Run this after a Qwen Code session has done its opening prefill. Early in the
# session is best: the reusable prefix is identical either way, but a long
# session writes a much larger file for no gain.
#
# Re-run it after upgrading @qwen-code/qwen-code or changing the tool set
# (MCP servers, extensions) — both change the system message, which silently
# invalidates the snapshot.
set -uo pipefail

HOST=${LLAMA_HOST:-http://127.0.0.1:8080}
SLOT_DIR=${LLAMA_SLOT_DIR:-$HOME/.local/state/llama-slots}
FILENAME=${1:-qwen-boot.bin}
MIN_TOKENS=${MIN_TOKENS:-20000}

slots_json=$(curl -sf --max-time 10 "$HOST/slots") || {
  echo "error: cannot reach $HOST/slots — is llama.service running?" >&2
  exit 1
}

# Pick the idle slot holding the most tokens. A busy slot cannot be saved, and
# the largest idle one is the one that just finished the big prefill.
read -r slot_id n_tokens < <(printf '%s' "$slots_json" | python3 -c '
import json, sys
slots = json.load(sys.stdin)
idle = [s for s in slots if not s.get("is_processing")]
if not idle:
    print("-1 0"); sys.exit()
best = max(idle, key=lambda s: s.get("n_prompt_tokens") or 0)
print(best["id"], best.get("n_prompt_tokens") or 0)
')

if [ "$slot_id" = "-1" ]; then
  echo "error: every slot is busy — wait for the request to finish and retry" >&2
  exit 1
fi

if [ "$n_tokens" -lt "$MIN_TOKENS" ]; then
  echo "refusing to save: slot $slot_id holds only $n_tokens tokens (min $MIN_TOKENS)." >&2
  echo "That usually means something other than Qwen Code was the last thing to" >&2
  echo "use the server. Saving now would overwrite a good snapshot with a short" >&2
  echo "one, which fails silently later. Start Qwen Code, send one message, retry." >&2
  exit 1
fi

echo "saving slot $slot_id ($n_tokens tokens) -> $SLOT_DIR/$FILENAME"

resp=$(curl -sf --max-time 300 -X POST "$HOST/slots/$slot_id?action=save" \
  -H 'Content-Type: application/json' \
  -d "{\"filename\": \"$FILENAME\"}") || {
  echo "error: save request failed. If the server reports that slots actions are" >&2
  echo "unsupported, --slot-save-path is missing from llama.service." >&2
  exit 1
}

printf '%s\n' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(sys.stdin.read()); sys.exit()
print("n_saved  =", d.get("n_saved"))
print("timings  =", d.get("timings"))
'

ls -lh "$SLOT_DIR/$FILENAME" 2>/dev/null || echo "warning: $SLOT_DIR/$FILENAME not on disk" >&2
