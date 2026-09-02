# llm3 — Ryzen 9 7940HS / Radeon 780M inference node

The 12-CU Phoenix sibling of the P14s/P16s work documented in the repo root. Same
~89.6 GB/s DDR5-5600 bandwidth wall, same model, one-third the price. Serves
`Qwen3.6-35B-A3B-Q8-780M` to the fleet router (`llm.stormes.net` → cloud1
`fleet-proxy` → `llm3.local:8080`).

See [RECREATE.md](RECREATE.md) for the from-scratch build. Byte-exact copies of
every config file are in [assets/](assets/).

## Hardware

| | |
|---|---|
| System | ALLOY9-7940HS mini-PC (Shanghai Hongnian Industrial) |
| CPU | AMD Ryzen 9 7940HS, 8C/16T Zen 4 (Phoenix APU) |
| GPU | Integrated Radeon 780M — RDNA 3, `gfx1103`, **12 CU** |
| RAM | 2 × 32 GB DDR5-5600 SODIMM, dual-channel → 61 GiB usable, ~89.6 GB/s theoretical |
| GPU memory | 576 MB VRAM carve-out + **56 GiB GTT** (`amdgpu.gttsize=57344`) — model is GTT-resident |
| Storage | 238 GB Fanxiang S501 NVMe, single ext4 root; models live in `/mnt/data/models` (plain directory on root fs, *not* a separate mount) |
| Swap | 8 GB `/swap.img` |

## Software stack

| | |
|---|---|
| OS | Ubuntu Server 26.04.1 LTS, kernel `7.0.0-30-generic` |
| Kernel cmdline | `amdgpu.gttsize=57344 ttm.pages_limit=14680064 ttm.page_pool_size=14680064 amd_iommu=off` |
| Vulkan | Mesa **26.1.7** (kisak-mesa PPA, not held), RADV; `libvulkan1 1.4.341` |
| llama.cpp | **b10173** (commit `e9fa0781f`), Vulkan build, gcc, `GGML_NATIVE=ON`, Release, at `/opt/llama/llama.cpp-b10173` |
| Backend | Vulkan only. rocBLAS ships no `gfx1103` Tensile kernels, so ROCm is a non-starter here (the repo root's `gfx1151` HSA-override trick does not apply — see OPTIMAL-SETTINGS notes in the fleet docs) |
| Model | `Qwen3.6-35B-A3B-Q8_0.gguf` (35.2 GiB, unsloth GGUF of [Qwen/Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)) + `mmproj-BF16.gguf` (0.9 GiB, vision) |
| Spare model | `Qwen3.6-35B-A3B-UD-Q6-MTP_K_XL.gguf` (30.4 GiB) kept in `/mnt/data/models/Qwen3.6-35B-A3B-MTP` — the pre-2026-07-30 serving quant, retained for rollback |

## Served configuration

Production unit `llama-qwen3.6-35b-q8.service` (full file in assets/): 256K context,
`-np 1`, `-b 8192 -ub 2048`, `-fa 1`, q8_0 KV, `--cache-ram 8192 --cache-reuse 256`,
`--no-mmap --fit off -ngl 999`, MTP self-speculation (`--spec-type draft-mtp
--spec-draft-n-max 2`, q8_0 draft KV), vision via mmproj, `--jinja
--reasoning-budget 2048`, sampling `temp 1.0 / top-p 0.95 / top-k 20 / min-p 0 /
presence 1.5`. Runs as root with `SupplementaryGroups=render video`.
`RADV_PERFTEST=nogttspill` is set but measured a no-op (see below).

**Known config drift (as of 2026-09-02, deliberate to leave, but be aware):**
- Unit `Description` says "3x256K" but the flags are `-np 1 -c 262144` (1×256K).
- The switchable-variant launcher (`assets/llama-launch`) claims to mirror
  production but carries `-np 2 -kvu`; the cloud1 proxy comments also say llm3
  runs `-np 2`. The *running* production unit is `-np 1`, no `-kvu`.
- `/etc/llama-variant.env` still holds `toolbox-sys` from an old experiment;
  `llama-variant.service` is disabled, so it is inert.

## Latest benchmarks (2026-09-02, this hardware, production config)

Protocol per the fleet's benchmark-rigor rules: interleaved arms, n=10/arm,
fixed-length prompts with unique fixed-width prefixes, `cache_prompt:false`,
`ignore_eos`, 256-token generation, state read back per run. Generation variance
on this box is ±3.3–3.9 t/s run-to-run (MTP acceptance noise at temp 1.0) —
**never trust a single-run generation number here.**

Steady-state, direct to `:8080`:

| Metric | Value |
|---|---|
| Prefill @ 3.1K-token prompt | **~402 t/s** |
| Prefill @ 8.1K-token prompt | **~380 t/s** |
| Generation (256 tok, MTP) | **~23 t/s** mean (spread 20–28) |
| Load power / temp | ~50 W / 68 °C |
| Fleet-bench cold-prefill baseline (2026-07-30, via HTTP harness) | 328.9 pp / 21.9 tg |

### DPM: forced `high` vs `auto` — dead tie (do not re-test)

`cpu-performance.service` forces `power_dpm_force_performance_level=high`. The
P14s finding that `auto` wins (−8.6% gen for `high`, −30 W) **does not transfer**:

| | `high` | `auto` |
|---|---|---|
| prefill t/s | 401.2 ±2.1 | 403.0 ±1.6 (+0.4%) |
| generation t/s | 23.23 ±3.27 | 23.07 ±3.63 (−0.7%, \|d\|/SE 0.1) |
| power / temp | 49.9 W / 68 °C | 47.2 W / 68 °C |

The laptop's `auto` win was thermal-envelope relief in a 14" chassis; this
mini-PC isn't thermally constrained, so both arms converge. Kept `high`.

### `-ub 1024` vs `2048` — on the plateau (kept 2048)

ABBA restart blocks (2048|1024|1024|2048), live `-ub` read back from the process:

| | `-ub 2048` (prod) | `-ub 1024` |
|---|---|---|
| prefill t/s @8K | 379.6 ±1.0 | 384.3 ±0.8 (+1.2%, \|d\|/SE 11.1 — real but trivial) |
| generation t/s | 24.49 ±3.93 | 22.08 ±3.46 (−9.8%, \|d\|/SE 1.5 — noise, not established) |

The P16s's +23% `-ub` win was escaping the 512 *default*; 2048 is already optimal
here within ~1%.

### Measured-negative ledger for this box (don't re-test)

- `RADV_PERFTEST=nogttspill` — no-op (P14s/P16s measurement; still set in the unit, droppable).
- Q6_K → Q8_0 gave only **+6% prefill** here vs +22.8% on 16-CU parts — 12 CUs
  lack the ALU headroom to exploit cheap dequant. Quant changes on llm3 buy
  quality/memory, not speed.
- Decode is purely bandwidth-bound: ~22 t/s is the DDR5-5600 hard cap for this
  model regardless of tuning.
- `amd_iommu=off` is worth +19–26% prefill / +15% gen (P14s measurement, applied
  here). If llm3 ever mysteriously loses ~20%, check this flag first — that
  exact regression happened on the P14s.

## Known issues

- **Silent freezes**: llm3 has frozen 3× (ARP-alive / SSH-dead, zero log
  forensics; last 2026-08-31, recovered clean on power-cycle). Hardware watchdog
  + netconsole proposed, not yet deployed. WoL state and MAC recorded in fleet notes.
- The two-model era (35B + small classifier on :8081) ended 2026-08-01;
  classification now rides the single 35B.

## assets/

Byte-exact copies from the live host: `llama-qwen3.6-35b-q8.service`,
`cpu-performance.service`, `llama-variant.service`, `llama-launch`,
`llama-variant`, and `llama-variants/` (the three `.env` variant definitions).
