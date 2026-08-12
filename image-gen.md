# p14 — local image generation

Investigation date: **2026-08-06/07**
Host: p14 (ThinkPad P14s Gen 6 AMD, Radeon 890M / gfx1150, 60 GB, GTT 49152 MiB)
Goal: run text-to-image locally and wire it into Qwen Code's built-in `image_gen` tool.

Companion to [`README.md`](README.md) (llama.cpp tuning) and [`voice-asr.md`](voice-asr.md).

---

## Status: built and staged, never run

Runtime compiled, models downloaded and verified. **No image has been generated yet** —
blocked on memory, see below. Nothing is installed to `/opt` and no service exists.

---

## Runtime

[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp) —
commit `c6beeef35526c6dc94b74a7fb69f9d2e6a2a7a12` (2026-08-06), shallow clone with
submodules at `~/src/stable-diffusion.cpp`.

```bash
cmake -B build -DSD_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DSD_BUILD_EXAMPLES=ON
cmake --build build -j 20 --config Release
```

Built clean, 0 errors, using the same toolchain installed for the whisper.cpp build
(`build-essential cmake glslc libvulkan-dev spirv-headers glslang-tools spirv-tools`).
Binaries: `~/src/stable-diffusion.cpp/build/bin/{sd-cli,sd-server}`.

GPU enumerates correctly:

```
ggml_vulkan: 0 = AMD Radeon 890M Graphics (RADV STRIX1) (radv) | uma: 1 | fp16: 1 |
             warp size: 64 | matrix cores: KHR_coopmat
```

`sd-server` exposes an **OpenAI-compatible `/v1/images/generations`** endpoint, plus
`/v1/images/edits` and an AUTOMATIC1111 compatibility layer.

## Models — all sha256-verified against HF metadata

In `/models`:

| file | bytes | role |
|---|---|---|
| `z_image_turbo-Q8_0.gguf` | 6577440704 | diffusion model (Z-Image-Turbo, 6B) |
| `Qwen3-4B-Instruct-2507-Q8_0.gguf` | 4280405600 | text encoder |
| `vae/diffusion_pytorch_model.safetensors` | 167666902 | VAE |

Sources: `leejet/Z-Image-Turbo-GGUF` (the sd.cpp author's own conversion),
`unsloth/Qwen3-4B-Instruct-2507-GGUF` (the real `unsloth` org — **not** `unslothai`,
which is their GitHub name and a different HF account), `Tongyi-MAI/Z-Image-Turbo`.

**Why Z-Image-Turbo over SDXL/FLUX:** step count dominates on a 16-CU iGPU. Z-Image needs
**8 steps** at 6B params vs 20–30 for SDXL and 12B for FLUX. Unlike the LLM workload, this
one is compute-bound, not bandwidth-bound.

**Why Q8_0:** same reasoning as §8 of the install doc — Q8_0 dequantizes trivially on this
silicon while K-quants need expensive unpacking. Applies to diffusion weights too. The text
encoder runs once per image so its quant matters far less.

Known-good settings from a Strix Halo write-up: **`--cfg-scale 1.0`** (required for the
Turbo distillation), flash attention on, VAE tiling with 0.5 overlap.

---

## The blocker — it does not fit alongside `llama.service`

Measured 2026-08-07 with llama running at its current 262k-context config:

| | |
|---|---|
| GTT ceiling | 49152 MiB |
| held by `llama.service` | 43372 MiB |
| **free GTT** | **5780 MiB** |
| needed by Z-Image + text encoder | **~10900 MiB** |
| free system RAM | ~11 GB |
| swap | **none configured** |

`--offload-to-cpu` moves the weights into system RAM, but that lands at ~11 GB needed
against ~11 GB available, with no swap to absorb the overshoot. **The likely outcome is the
OOM killer, and the largest target on the box is `llama.service` itself.**

> ⚠ **Do not try `--offload-to-cpu` while llama is serving.** Stop `llama.service` first.

### Options when picking this back up

1. **Stop `llama.service` for the duration** — frees ~43 GB, lets the model run fully on
   GPU rather than streaming from RAM. Simplest, and gives honest timings.
2. **Trim llama's context.** `-c 262144` → `-c 65536` frees roughly 2.5 GB. Not enough on
   its own; would still need offload.
3. **96 GB RAM.** Lenovo officially supports 2×48 GB DDR5-5600 on this chassis (the SMBIOS
   `Maximum Capacity: 64 GB` is stale). At 96 GB all three stacks fit with ~29 GB spare —
   see the budget in the research notes. Would want `amdgpu.gttsize` raised to ~61440 with
   `ttm.pages_limit`/`ttm.page_pool_size` at `15728640`. **Buys concurrency, not speed** —
   memory bandwidth is unchanged at ~89.6 GB/s.

Even with memory solved, all three workloads contend for the same 16 CUs. Fitting is
necessary, not sufficient — image generation on demand is probably right regardless.

## First command to run (untested)

```bash
systemctl --user stop llama.service     # see blocker above

cd ~/src/stable-diffusion.cpp
./build/bin/sd-cli -M img_gen \
  --diffusion-model /models/z_image_turbo-Q8_0.gguf \
  --vae /models/vae/diffusion_pytorch_model.safetensors \
  --llm /models/Qwen3-4B-Instruct-2507-Q8_0.gguf \
  -p "a photograph of a red bicycle against a white wall" \
  --cfg-scale 1.0 --steps 8 -W 512 -H 512 \
  --diffusion-fa -o /tmp/test.png -v

systemctl --user start llama.service
```

> ⚠ **Check GPU DPM before believing any timing.** It resets to `auto` on every boot and
> sits at 65–75% of peak clock under load. See `README.md` §1 and `set-dpm-high.sh`.
> As of 2026-08-07 it is deliberately left at `auto`.

**No published benchmark exists for image generation on a 890M.** Everything online is
Strix *Halo* (Radeon 8060S, 40 CU); this is Strix *Point* at 16 CU, so scale down ~2.5×.
Expect tens of seconds per 1024×1024 at 8 steps — extrapolation, not data.

---

## Wiring into Qwen Code — needs HTTPS

`imageModel` requires the provider entry to have `imageOnly: true`, an `envKey`, **and an
HTTPS `baseUrl`**. From the bundled settings doc:

> The selected model must have `imageOnly: true`, an HTTPS `baseUrl`, and `envKey` in
> `modelProviders`. Leave empty to keep the tool unavailable.

`sd-server` serves plain HTTP on loopback, so this needs a local TLS terminator (Caddy or
nginx with an mkcert cert, plus `NODE_EXTRA_CA_CERTS` so Node trusts it).

> **Voice and image differ here.** `voiceModel` explicitly exempts loopback from the HTTPS
> requirement (`isLoopbackHost` accepts `localhost`, `127.0.0.1`, `::1`); `imageModel` does
> not. Do not assume symmetry — see `voice-asr.md`.

Alternatively skip the `image_gen` tool entirely and drive `sd-server` directly.

---

## Downloading — use `hf`, not curl/wget

Set up during this session and **much faster**: measured **8–22 MB/s** effective vs wget's
**1.7 MB/s**, because xet reconstructs chunks locally (file growth ran ~8× the NIC receive
rate). It also verifies hashes itself — the HF CDN silently truncated three separate
wget/curl downloads earlier, and `curl -C -` corrupted one by appending a full body onto a
partial file.

```bash
hf download leejet/Z-Image-Turbo-GGUF --include "z_image_turbo-Q8_0.gguf" --local-dir /models
```

`hf` is at `~/.local/bin/hf` → `~/.venvs/hf/bin/hf` (huggingface_hub 1.26.1 + hf-xet 1.6.0).
The apt package was removed as redundant. Note `hf` writes to
`<local-dir>/.cache/huggingface/download/*.incomplete` and only moves the file into place
after verification — **so a running download looks like nothing is happening.** Watch with:

```bash
watch -n5 'find /models/.cache/huggingface -name "*.incomplete" -printf "%s\n"'
```

## Next steps

1. Stop llama, run the first generation, record wall-clock and GTT footprint.
2. If it works, decide: install to `/opt/sd`, and whether `sd-server` becomes a user unit
   (on-demand is probably better than resident, given the memory situation).
3. Only then consider the TLS terminator for Qwen Code integration.
