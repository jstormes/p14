#!/usr/bin/env bash
# Decisive, client-independent retest of llama.cpp slot save/restore.
#
# README.md records restore as a no-op on build 458: bytes load, reported token
# count is right, and the prefix matcher then ignores it. disk-cache.md revises
# *why* — the handler does populate the slot's token list at
# server-context.cpp:2652, so the recorded mechanism was wrong and the cause is
# unexplained rather than explained.
#
# Three conditions distinguish this box from the one third-party setup that
# reportedly works on this model: `--parallel 1`, restoring immediately before
# the request rather than once at boot, and injecting cache_prompt / n_keep.
# `-np 1` became the production setting on 2026-08-10 for unrelated reasons, so
# this run costs nothing to set up.
#
# The control is the point. Step 2 proves the prefix matcher works for this
# exact prompt on a live server; only then does step 5's number mean anything.
#
#   1. cold request              -> expect 0 cached
#   2. same request again        -> CONTROL, expect ~100% cached
#   3. save slot 0 to disk
#   4. restart llama.service     -> RAM cache is gone
#   5. restore, then immediately resend  -> the question
#
# Usage:  ./slot-restore-probe.sh [--tokens N]
set -uo pipefail

HOST=${LLAMA_HOST:-http://127.0.0.1:8080}
MODEL=${LLAMA_MODEL:-Qwen3.6-35B-A3B}
SLOT_DIR=${LLAMA_SLOT_DIR:-$HOME/.local/state/llama-slots}
SNAP=slot-restore-probe.bin
TOKENS=6000

while [ $# -gt 0 ]; do
  case "$1" in
    --tokens) TOKENS=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# A run-unique nonce so step 1 is genuinely cold no matter what is cached.
NONCE="probe-$(date +%s)-$$"

payload() {
  # $1 = extra JSON fields (may be empty)
  python3 - "$NONCE" "$TOKENS" "$1" <<'PY'
import json, sys
nonce, tokens, extra = sys.argv[1], int(sys.argv[2]), sys.argv[3]
filler = "lorem ipsum dolor sit amet consectetur adipiscing elit. "
body = {
    "model": "%%MODEL%%",
    "messages": [
        {"role": "system", "content": f"Probe {nonce}.\n" + filler * max(1, tokens // 7)},
        {"role": "user", "content": "Reply with the single word: ok"},
    ],
    "max_tokens": 1,
    "stream": False,
}
if extra:
    body.update(json.loads(extra))
print(json.dumps(body))
PY
}

send() {
  local label=$1 extra=${2:-}
  local body
  body=$(payload "$extra" | sed "s/%%MODEL%%/$MODEL/")
  local start end
  start=$(date +%s.%N)
  local resp
  resp=$(curl -sf --max-time 900 -X POST "$HOST/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$body") || {
      echo "  $label: REQUEST FAILED" >&2; return 1; }
  end=$(date +%s.%N)
  printf '%s' "$resp" | python3 -c "
import json, sys
d = json.load(sys.stdin)
u = d.get('usage', {})
c = (u.get('prompt_tokens_details') or {}).get('cached_tokens', 0)
p = u.get('prompt_tokens', 0) or 1
print(f\"  {'$label':<34} {$end - $start:7.2f}s  prompt {p:>6,}  cached {c:>6,} ({100.0*c/p:5.1f}%)\")
"
}

slot_action() {
  curl -sf --max-time 900 -X POST "$HOST/slots/0?action=$1" \
    -H 'Content-Type: application/json' -d "{\"filename\": \"$SNAP\"}"
}

wait_healthy() {
  for _ in $(seq 1 120); do
    curl -sf --max-time 2 -o /dev/null "$HOST/health" && return 0
    sleep 1
  done
  echo "server not healthy" >&2; return 1
}

echo "slot-restore probe — prefix ~${TOKENS} tokens, nonce ${NONCE}"
echo "server: $(curl -sf "$HOST/props" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("build_info","?"))' 2>/dev/null || echo '?')"
echo

echo "1/5  cold"
send "cold" || exit 1

echo "2/5  control — same request, live server"
send "control (RAM cache)" || exit 1

echo "3/5  save slot 0"
slot_action save | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  n_saved={d.get('n_saved')}  n_written={d.get('n_written'):,}  {d.get('timings')}\")" || {
  echo "  save failed — is --slot-save-path set?" >&2; exit 1; }
ls -lh "$SLOT_DIR/$SNAP" 2>/dev/null | awk '{print "  on disk:", $5}'

echo "4/5  restart llama.service (drops the RAM cache)"
systemctl --user restart llama.service && wait_healthy || exit 1
echo "  back up"

echo "5/5  restore, then immediately resend"
slot_action restore | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  n_restored={d.get('n_restored')}  n_read={d.get('n_read'):,}  {d.get('timings')}\")" || {
  echo "  restore failed" >&2; exit 1; }
send "after restore" || exit 1
send "after restore + cache_prompt/n_keep" '{"cache_prompt": true, "n_keep": -1}' || exit 1

echo
echo "Read step 2 first. If the control is ~100% and 'after restore' is 0%, restore is"
echo "still inert and the fork is the only route. If 'after restore' is high, the disk"
echo "cache is a proxy or an ExecStartPost, not a C++ project."
rm -f "$SLOT_DIR/$SNAP"
