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
| OS | Ubuntu Server 26.04.1 LTS, kernel `7.0.0-43-generic` (as of 2026-11-11) |
| Kernel cmdline | `amdgpu.gttsize=57344 ttm.pages_limit=14680064 ttm.page_pool_size=14680064 amd_iommu=off` + the `crashkernel=` reservation added by `kdump-tools` |
| Vulkan | Mesa **26.2.6** (kisak-mesa PPA, not held, so routine `apt upgrade` takes Mesa bumps; 26.2.4/26.2.5/26.2.6 each A/B'd perf-neutral), RADV; `libvulkan1 1.4.341` |
| llama.cpp | **strix-halo-llamacpp toolbox v0.7.8.1** (`8e9dcfeb`) Vulkan `bin/` on system Mesa, at `/opt/llama/strix-toolbox-0.7.8.1` (production since 2026-10-27). Older source builds kept for rollback: b11869 at `/opt/llama/llama.cpp-b11869`, b10173 (commit `e9fa0781f`, gcc, `GGML_NATIVE=ON`) at `/opt/llama/llama.cpp-b10173` |
| Backend | Vulkan only. rocBLAS ships no `gfx1103` Tensile kernels, so ROCm is a non-starter here (the repo root's `gfx1151` HSA-override trick does not apply — see OPTIMAL-SETTINGS notes in the fleet docs) |
| Model | `Qwen3.6-35B-A3B-Q8_0.gguf` (35.2 GiB, unsloth GGUF of [Qwen/Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)) + `mmproj-BF16.gguf` (0.9 GiB, vision) |
| Spare model | `Qwen3.6-35B-A3B-UD-Q6-MTP_K_XL.gguf` (30.4 GiB) kept in `/mnt/data/models/Qwen3.6-35B-A3B-MTP` — the pre-2026-07-30 serving quant, retained for rollback |

## Served configuration

Production is `llama-variant.service` → `assets/llama-launch` (see below): 256K context,
`-np 2 -kvu` (shared KV pool), `-b 8192 -ub 2048`, `-fa 1`, q8_0 KV, `--cache-ram 8192 --cache-reuse 256`,
`--no-mmap --fit off -ngl 999` (`-lm none` on the b11869/halo arms), `--image-min-tokens 1024`, MTP self-speculation (`--spec-type draft-mtp
--spec-draft-n-max 2`, q8_0 draft KV), vision via mmproj, `--jinja
--reasoning-budget 2048`, sampling `temp 1.0 / top-p 0.95 / top-k 20 / min-p 0 /
presence 1.5`. Runs as root with `SupplementaryGroups=render video`.
**`RADV_PERFTEST=nogttspill` was dropped on 2026-10-26.** It caused DeviceLost crashes on this 576 MiB-VRAM APU, at zero speed cost to remove (see [../RADV-NOGTTSPILL.md](../RADV-NOGTTSPILL.md)). Production ran `llama-variant` → `b11869-prob-spill` from then, and since **2026-10-27 runs `tb0781-sys-spill`** (strix-halo-llamacpp toolbox v0.7.8.1 `bin/` on system Mesa 26.2.5, no `nogttspill`; `assets/llama-variants/tb0781-sys-spill.env`). Measured against b11869-prob-spill over mirrored launches: prefill +7.3% at 3K, +13.4% at 16.7K, +26.8% at 32K cold (340 → 432 t/s), decode parity, 8-concurrent aggregate −5.2%; 5/5 launches crash-free ([benchmarks/tb0781-vs-b11869-20261027.tsv](benchmarks/tb0781-vs-b11869-20261027.tsv)). Rollback: `llama-variant b11869-prob-spill`.

**Production unit (since 2026-10-25): `llama-variant.service`** (enabled), which runs
`assets/llama-launch` with the build selected by `/etc/llama-variant.env`
(currently `tb0781-sys-spill`). The launcher's flags are what is actually served:
`-c 262144 -np 2 -kvu` (two slots sharing one unified 256K KV pool; `/props`
reports `total_slots 2`, `n_ctx 262144`), which matches the cloud1 proxy's
`-np 2` comment. The old `llama-qwen3.6-35b-q8.service` (`-np 1`, no `-kvu`)
is **disabled** and kept only as a reference; its `nogttspill` line must be
removed before it is ever re-enabled. `llama-variant.service` is ordered
`After=cpu-performance.service` so it still gets the GPU-readiness boot gate.

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

- `RADV_PERFTEST=nogttspill` — **not a no-op: it causes DeviceLost crashes** (`Not enough memory for command submission`). Dropped from production 2026-10-26; speed-neutral (decode −0.4%, prefill −0.3%). See [../RADV-NOGTTSPILL.md](../RADV-NOGTTSPILL.md).
- Q6_K → Q8_0 gave only **+6% prefill** here vs +22.8% on 16-CU parts — 12 CUs
  lack the ALU headroom to exploit cheap dequant. Quant changes on llm3 buy
  quality/memory, not speed.
- Decode is purely bandwidth-bound: ~22 t/s is the DDR5-5600 hard cap for this
  model regardless of tuning.
- `amd_iommu=off` is worth +19–26% prefill / +15% gen (P14s measurement, applied
  here). If llm3 ever mysteriously loses ~20%, check this flag first — that
  exact regression happened on the P14s.

## llm3 vs P14s — same model, same bandwidth wall

Both machines serve the identical `Qwen3.6-35B-A3B Q8_0` + MTP over Vulkan/RADV
with `amd_iommu=off`, and both sit on the same ~89.6 GB/s DDR5-5600 dual-channel
bus. P14s numbers from the repo root; llm3 numbers from 2026-09-02 above.

| | **llm3** (mini-PC) | **P14s** (laptop) |
|---|---|---|
| GPU | Radeon 780M, RDNA 3 `gfx1103`, **12 CU** | Radeon 890M, RDNA 3.5 `gfx1150`, **16 CU** |
| Prefill | **~400 t/s** @3K, ~380 @8K, ~330 cold/long | **~418 t/s** (DPM auto), 473 at `high`; ~340–375 @41.6K |
| Generation | **~23 t/s** (spread 20–28) | **~22.6 t/s** |
| Load power / temp | ~50 W / 68 °C, no throttling | 24 W / 71 °C on `auto`; `high` = 53 W / 95 °C and −8.6% gen |
| DPM sensitivity | none (dead tie, measured) | large — 14" thermal envelope |
| Warm-turn latency | full prefill after every restart | ~0.2 s via the disk-cache fork |

- **Generation is a dead tie (~22–23 t/s) and always will be** — decode is purely
  bandwidth-bound and both are pinned to the same bus. Same tie llm3 fought the
  P16s to.
- **Prefill: P14s wins ~+5–15%** depending on depth — but that comes from +33%
  more CUs, so per CU-GHz llm3 is the *more* efficient machine (echoing the P16s
  prefill-anomaly finding). The 473 headline needs DPM `high`, which costs the
  P14s 8.6% generation and a 95 °C package; llm3 gets its numbers at 68 °C with
  DPM irrelevant.
- **The P14s's real lead is UX, not throughput**: its disk-cache fork turns a
  ~97 s cold prefill into ~0.2 s at login. llm3 has no equivalent — the one
  open idea from the 2026-09-02 review.

One line: as inference engines they are the same machine — identical generation,
single-digit prefill difference — the P14s trading llm3's thermal indifference
for portability and a much slicker warm start.

## Known issues

- **Silent freezes**: llm3 has frozen 3× (ARP-alive / SSH-dead, zero log
  forensics; last 2026-08-31, recovered clean on power-cycle). **Hang recovery
  deployed 2026-10-25** (`assets/hang-recovery/`, RECREATE step 12): the
  `sp5100_tco` chipset watchdog petted by systemd (60 s), soft/hard lockup →
  panic → kdump → auto-reboot, and netconsole streaming kernel messages to
  another host so the next freeze leaves forensics. No freeze since.
- The two-model era (35B + small classifier on :8081) ended 2026-08-01;
  classification now rides the single 35B.

## assets/

Byte-exact copies from the live host: `llama-qwen3.6-35b-q8.service`,
`cpu-performance.service`, `llama-variant.service`, `llama-launch`,
`llama-variant`, and `llama-variants/` (every `.env` variant definition on the
host, including research arms such as `halo-prob*` and `b11869*`).
`hang-recovery/` holds the watchdog / panic / netconsole files; the
netconsole script has the receiver's IP and MAC redacted (`REMOTE_IP`,
`REMOTE_MAC`).
