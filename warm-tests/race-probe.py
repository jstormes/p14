#!/usr/bin/env python3
"""Measure the warm-vs-real-turn race that TODO.md item 6.1 left open.

`warmStartupPrompt` is fire-and-forget: it fires the startup prompt at session
init, and a user who types immediately runs their real turn *concurrently* with
it. The two share a long prefix but differ in the final user message, so with
`-np 4` they land on different slots and may both prefill the whole thing.

This reproduces that mechanically, without qwen-code and without a TUI:

  arm "race"   - warm and real turn fired together (user types instantly)
  arm "serial" - real turn fired after the warm completes (user reads first)

The interesting comparison is the *real turn's* latency, because that is the
only number the user experiences. Total GPU time matters too, on a laptop.

Usage:
    ./race-probe.py [--prefix-tokens N] [--label TEXT]

Run it once per `-np` setting and compare. The prefix carries a run-unique
nonce so every run starts genuinely cold regardless of what is in the cache.
"""

import argparse
import json
import sys
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

HOST = "http://127.0.0.1:8080"
MODEL = "Qwen3.6-35B-A3B"

# ~7 tokens per repetition of the filler sentence, measured against this
# model's tokenizer; close enough for sizing a probe.
FILLER = "lorem ipsum dolor sit amet consectetur adipiscing elit. "
TOKENS_PER_FILLER = 7


def build_prefix(nonce: str, target_tokens: int) -> str:
    """A prefix that is cold by construction and roughly `target_tokens` long."""
    reps = max(1, target_tokens // TOKENS_PER_FILLER)
    return f"Session nonce {nonce}. Reference material follows.\n" + FILLER * reps


def post(prefix: str, user_message: str, max_tokens: int) -> dict:
    body = json.dumps(
        {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": prefix},
                {"role": "user", "content": user_message},
            ],
            "max_tokens": max_tokens,
            "stream": False,
        }
    ).encode()

    req = urllib.request.Request(
        f"{HOST}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )

    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=900) as resp:
        payload = json.load(resp)
    elapsed = time.monotonic() - started

    usage = payload.get("usage", {})
    details = usage.get("prompt_tokens_details", {}) or {}
    return {
        "seconds": elapsed,
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "cached_tokens": details.get("cached_tokens", 0),
    }


def show(name: str, r: dict) -> None:
    prompt = r["prompt_tokens"] or 1
    pct = 100.0 * r["cached_tokens"] / prompt
    print(
        f"  {name:<12} {r['seconds']:7.2f}s   "
        f"prompt {r['prompt_tokens']:>7,}   "
        f"cached {r['cached_tokens']:>7,} ({pct:5.1f}%)"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix-tokens", type=int, default=15000)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    banner = f"race-probe  prefix≈{args.prefix_tokens:,} tokens"
    if args.label:
        banner += f"  [{args.label}]"
    print(banner)
    print("=" * len(banner))

    # ── Arm 1: race. Warm and real turn fired together. ────────────────────
    # Distinct nonce per arm so neither arm can warm the other.
    prefix = build_prefix(f"race-{uuid.uuid4()}", args.prefix_tokens)
    print("\nrace   (warm + real turn concurrent — user types immediately)")
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=2) as pool:
        warm_f = pool.submit(post, prefix, "Warm.", 1)
        # A beat, so the warm is genuinely first in the queue — the client
        # fires it at init, a hair before any keystroke can land.
        time.sleep(0.25)
        real_f = pool.submit(post, prefix, "Summarise the reference material.", 16)
        warm, real = warm_f.result(), real_f.result()
    race_wall = time.monotonic() - started
    show("warm", warm)
    show("real turn", real)
    print(f"  {'wall clock':<12} {race_wall:7.2f}s  ← both requests done")

    # ── Arm 2: serial. Real turn only after the warm lands. ────────────────
    prefix = build_prefix(f"serial-{uuid.uuid4()}", args.prefix_tokens)
    print("\nserial (real turn after the warm completes — user reads first)")
    started = time.monotonic()
    warm = post(prefix, "Warm.", 1)
    real = post(prefix, "Summarise the reference material.", 16)
    serial_wall = time.monotonic() - started
    show("warm", warm)
    show("real turn", real)
    print(f"  {'wall clock':<12} {serial_wall:7.2f}s  ← both requests done")

    print(
        "\nThe number the user feels is the real turn. The wall clock is what "
        "the GPU spent."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
