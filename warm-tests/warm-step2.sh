#!/usr/bin/env bash
# STEP 2: same directory, warm DISABLED, interactive, send one real message.
# If step 1's warm produced the correct prefix, this turn's prompt eval should
# be TINY (cache hit). If the prefix diverged (e.g. tools stripped), it will be
# ~34.8k again — the silent-failure signature.
set -u
TESTDIR="$1"
CLI=/home/jstormes/code/qwen-code/dist/cli.js
OUT="$TESTDIR/step2-cli.log"
FIFO="$TESTDIR/stdin2.fifo"

# Warm OFF for this run — we are measuring the *real* turn only.
cat > "$TESTDIR/.qwen/settings.json" <<'EOF'
{
  "model": {
    "warmStartupPrompt": false
  }
}
EOF

cd "$TESTDIR" || exit 1
rm -f "$FIFO"; mkfifo "$FIFO"

CURSOR=$(journalctl --user -u llama.service -n 0 --show-cursor --no-pager 2>/dev/null | grep -oP '(?<=-- cursor: ).*')
echo "journal cursor captured"

script -qec "node $CLI" /dev/null < "$FIFO" > "$OUT" 2>&1 &
SCRIPT_PID=$!
exec 3> "$FIFO"

# Let the UI settle before typing (no warm request now, so this is quick).
sleep 20
echo "sending real message at $(date '+%H:%M:%S')"
printf 'Reply with exactly: OK\r' >&3
T0=$(date +%s)

# Wait for the server to finish a task after our message.
DEADLINE=$((SECONDS + 200))
while [ $SECONDS -lt $DEADLINE ]; do
  if journalctl --user -u llama.service --after-cursor "$CURSOR" --no-pager 2>/dev/null \
     | grep -q "prompt eval time"; then
    sleep 3
    break
  fi
  sleep 3
done
T1=$(date +%s)
echo "elapsed since send: $((T1-T0))s"

exec 3>&-
kill "$SCRIPT_PID" 2>/dev/null
pkill -f "node $CLI" 2>/dev/null
sleep 2
rm -f "$FIFO"

echo "=== SERVER: prompt evals since message ==="
journalctl --user -u llama.service --after-cursor "$CURSOR" --no-pager 2>/dev/null \
  | grep -E "prompt eval time|launch_slot_|release:" | tail -12
echo "=== done ==="
