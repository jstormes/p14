# `RADV_PERFTEST=nogttspill` causes DeviceLost crashes on AMD APUs — never set it

**Finding, 2026-10-26.** Earlier notes in this repo called `RADV_PERFTEST=nogttspill` a measured
no-op, "set but droppable". It is worse than that. On an APU with a small firmware VRAM carve-out,
it is the root cause of intermittent `vk::DeviceLostError` crashes in llama.cpp's Vulkan backend.
Dropping it costs nothing measurable in speed.

## Symptom

```
radv/amdgpu: Not enough memory for command submission.
ggml_vulkan: device lost on Vulkan0
terminate called after throwing an instance of 'vk::DeviceLostError'
  what():  vk::Queue::submit: ErrorDeviceLost
```

The kernel log fills with hundreds of `amdgpu ... [drm] *ERROR* Not enough memory for command
submission!`. **GTT is nowhere near full** (55-67 of 100 GiB on the Strix Halo box), which is why
the error looks unexplained. The crash depends on the launch: the same config can crash in seconds on one
start and run for hours on the next. It hits during cold long-prompt prefill with MTP speculative
decoding, which allocates more GPU memory mid-request (prompt checkpoints, draft contexts).

Seen with:
- halo-box `strix-llama.cpp` b1030 + `--spec-draft-sampling probabilistic` on the Radeon 8060S
  (Strix Halo): crashed **within 16 s on every launch**
- Gemma-4-31B with a separate MTP draft model, on strix-halo-llamacpp toolbox v0.7.8.1: 1 crash in 4 launches
- toolbox v0.7.8.1 on llm3 (Radeon 780M, this repo's `Ryzen-9-7940HS/`): crashed on 2 of 3 launches

## Cause

These APUs reserve only a tiny VRAM carve-out in firmware: **512 MiB on the 8060S box, 576 MiB on
llm3**. Everything else lives in GTT (system RAM).

- In Mesa (`src/amd/vulkan/winsys/amdgpu/radv_amdgpu_bo.c`, ~line 583 in 26.2.4), RADV normally
  adds GTT to the preferred domains of buffers from its VRAM heap. That makes them "spillable", and the
  kernel can place them in system RAM when VRAM is short. **`nogttspill` turns that off**, so those
  buffers become VRAM-only.
- llama-server requests ~52 GiB from the VRAM heap with only ~170 MiB actually resident. With the
  flag set, the kernel keeps trying to migrate those buffers back into the carve-out.
- In the kernel (`drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c`), `amdgpu_cs_parser_bos()` validates
  every buffer a submission references and fails with `-ENOMEM`. That prints the message above, and
  the Vulkan driver reports a lost device.
- Likely mechanism, inferred from the kernel source and not traced: user buffers get GTT added as
  a fallback, but kernel-type buffers such as GPU page tables don't (`amdgpu_object.c`,
  `amdgpu_bo_create`). Once VRAM-only user buffers fill the carve-out, a submission that needs a
  new page table has nowhere to put it.

VRAM sits at ~480-536 MiB **with or without** the flag, so "VRAM is full" is not the trigger by
itself. The difference is whether the kernel is allowed to make room.

## Evidence

Strix Halo (8060S, 512 MiB carve-out), halo-box b1030 + probabilistic MTP drafts at `-b 8192`.
Stress = 3 rounds of (cold 16.7K-token prefill ×3, 8 concurrent requests ×2), with launches
alternated, 10 Hz VRAM sampling:

| `RADV_PERFTEST` | Launches | Crashed | VRAM peak |
|---|---|---|---|
| `nogttspill` | 2 | **2** (both at 16 s) | 503 MiB |
| empty | 4 | **0** (full 5-min stress each) | 480 MiB |

It was then confirmed under a full benchmark run: 4 more launches without the flag, every workload
including 8-concurrent, 0 DeviceLost, 0 ENOMEM.

## Speed cost of dropping it: none

Mirrored launches (with, without, without, with); mean t/s, |d|/SE in brackets (≥2 = real):

**Strix Halo, toolbox v0.7.8.1, Qwen3.6-35B-A3B Q8_0 + MTP, `-np 4`:**

| Workload | With `nogttspill` | Without | Δ |
|---|---|---|---|
| Prefill, 16.7K cold | 2069 | 2068 | −0.0% (0.8) |
| Decode | 57.8 | 56.8 | −1.8% (1.1) |
| Decode, hard prompts | 52.0 | 53.2 | +2.4% (1.7) |
| 8 concurrent, aggregate | 61.3 | 62.2 | +1.5% (1.7) |
| Decode at 32K context | 53.9 | 55.6 | +3.2% (1.8) |
| Decode at 128K context | 42.2 | 43.3 | +2.6% (1.8) |

**llm3 (780M), upstream b11869 + probabilistic drafts, `-np 2 -kvu`:**

| Workload | With `nogttspill` | Without | Δ |
|---|---|---|---|
| Decode | 21.0 | 21.0 | −0.4% (0.2) |
| Decode, hard prompts | 19.1 | 18.9 | −0.9% (0.7) |
| Prefill, 16.7K cold | 419.0 | 417.7 | −0.3% (4.7, real but ~1 t/s) |

This matches the earlier P14s/P16s measurement, which found pure noise.

## Rule

- **On any AMD APU (UMA, small carve-out), never set `RADV_PERFTEST=nogttspill`.**
- On a discrete GPU with gigabytes of real VRAM, the flag is a different trade-off. It is still
  unnecessary for llama.cpp.
- To check a running server: `sudo cat /proc/$(pgrep -x llama-server)/environ | tr '\0' '\n' | grep RADV`
- To see the carve-out and how full it is: `/sys/class/drm/card*/device/mem_info_vram_{total,used}`.

## Applied

- **llm3** (`Ryzen-9-7940HS/`): production switched 2026-10-26 to variant `b11869-prob-spill`
  (`assets/llama-variants/b11869-prob-spill.env`, which drops the flag with an empty
  `RADV_PERFTEST=` line). The launcher (`assets/llama-launch`) now uses
  `${RADV_PERFTEST-nogttspill}` so that an empty value sticks. Verified through the proxy:
  reasoning and structured tool calls work.
- **P14s / P16s:** their launchers never set it. Unaffected.
- The old disabled llm3 unit `assets/llama-qwen3.6-35b-q8.service` still sets it. If you ever
  roll back to that unit, delete that line first.
