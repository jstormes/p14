#!/usr/bin/env bash
# STEP 1: launch the modified CLI interactively, let the warm request fire,
# send NO user message, then kill it. Isolates the warm from any real turn.
set -u
TESTDIR="$1"
CLI=/home/jstormes/code/qwen-code/dist/cli.js
OUT="$TESTDIR/step1-cli.log"
FIFO="$TESTDIR/stdin.fifo"

cd "$TESTDIR" || exit 1
rm -f "$FIFO"; mkfifo "$FIFO"

# A pty is required for interactive mode; keep stdin open via the fifo so the
# CLI does not see EOF and exit before the warm request completes.
script -qec "node $CLI" /dev/null < "$FIFO" > "$OUT" 2>&1 &
SCRIPT_PID=$!
exec 3> "$FIFO"   # hold the write end open

echo "started pid=$SCRIPT_PID, waiting for warm prefill in journal..."

# Poll the server journal for a large prompt eval (the warm request).
DEADLINE=$((SECONDS + 240))
FOUND=""
while [ $SECONDS -lt $DEADLINE ]; do
  FOUND=$(journalctl --user -u llama.service --since "3 min ago" --no-pager 2>/dev/null \
          | grep -oE "prompt eval time =[^/]*/ *[0-9]+ tokens" \
          | awk '{print $NF-1}' 2>/dev/null | tail -1)
  BIG=$(journalctl --user -u llama.service --since "3 min ago" --no-pager 2>/dev/null \
        | grep -E "prompt eval time" | grep -oE "/ *[0-9]{4,} tokens" | tail -1)
  if [ -n "$BIG" ]; then
    echo "large prefill observed: $BIG"
    break
  fi
  sleep 5
done

echo "--- killing CLI ---"
exec 3>&-
kill "$SCRIPT_PID" 2>/dev/null
pkill -f "node $CLI" 2>/dev/null
sleep 2
rm -f "$FIFO"

echo "=== CLI output (first 25 lines) ==="
head -25 "$OUT" 2>/dev/null
echo "=== done ==="
