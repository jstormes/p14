#!/usr/bin/env python3
"""Probe: does a max_tokens=1 request populate llama.cpp's --cache-ram prompt cache
so that a LATER request with the same prefix but a different suffix reuses it?

Mirrors the qwen warm-start scenario:
  stable prefix (system instruction + startup context)  +  varying user message
"""
import json
import sys
import time
import urllib.request

URL = "http://127.0.0.1:8080/v1/chat/completions"
NONCE = sys.argv[1] if len(sys.argv) > 1 else str(int(time.time()))

# ~8-10k tokens of stable prefix. Nonce makes this run cold regardless of history.
PARA = (
    "The quick brown fox jumps over the lazy dog while the engineer considers "
    "the cache eviction policy and its effect on prefill latency. "
)
PREFIX = f"[probe-nonce {NONCE}] " + (PARA * 600)


def post(user_msg, max_tokens, label):
    body = json.dumps({
        "messages": [
            {"role": "system", "content": PREFIX},
            {"role": "user", "content": user_msg},
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
        "cache_prompt": True,
    }).encode()
    req = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"}
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        resp = json.load(r)
    dt = time.time() - t0
    usage = resp.get("usage", {})
    prompt_toks = usage.get("prompt_tokens", 0)
    cached = usage.get("prompt_tokens_details", {}).get("cached_tokens", 0)
    pct = (100.0 * cached / prompt_toks) if prompt_toks else 0.0
    print(f"{label:<42} prompt={prompt_toks:>6}  cached={cached:>6}  "
          f"({pct:5.1f}%)  {dt:6.2f}s  max_tokens={max_tokens}")
    return cached, prompt_toks


print(f"nonce = {NONCE}\n")
print("STEP 1 — warm request, minimal generation (the proposed startup warm)")
post("Warm.", 1, "  1. warm (max_tokens=1), cold prefix")

print("\nSTEP 2 — the real first turn: same prefix, DIFFERENT user message")
post("What is 2+2? Answer briefly.", 16, "  2. real turn after warm")

print("\nSTEP 3 — control: identical repeat of step 2 (upper bound)")
post("What is 2+2? Answer briefly.", 16, "  3. identical repeat")

print("\nSTEP 4 — control: a prefix never sent before (should be ~0%)")
PREFIX = f"[probe-nonce {NONCE}-different] " + (PARA * 600)
post("What is 2+2? Answer briefly.", 16, "  4. unseen prefix")
