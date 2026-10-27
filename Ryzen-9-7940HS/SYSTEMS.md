# Systems — 7940HS-class hardware

Known and candidate machines built on the Phoenix/Hawk Point + Radeon 780M
platform this folder documents. Anything here should hit llm3-class numbers
(~380–400 t/s prefill, ~23 t/s generation on the 35B-A3B Q8_0 — see
[README.md](README.md)) **if** it has dual-channel DDR5-5600 and adequate
cooling; both caveats have bitten before (P14s thermal-envelope findings,
bandwidth being the hard cap).

> **⚠️ Before buying anything on this page, verify the memory — it IS the
> product.** Generation speed is set entirely by memory bandwidth, and capacity
> decides which models fit at all. Confirm all three, from the maker's spec
> sheet for the exact SKU, not the listing title:
>
> 1. **Amount** — ≥64 GB installed *or* two SODIMM slots rated for it. "Up to
>    64 GB" in a listing sometimes means a soldered 32 GB variant exists —
>    check the exact model number.
> 2. **Speed** — DDR5-5600 for llm3-class (~22–23 t/s gen). DDR5-4800 costs
>    ~15% generation; LPDDR5X-7500+ beats 5600 but is soldered, so rule 1
>    still decides.
> 3. **Channels** — must run dual-channel/dual-rank. A single-DIMM config
>    halves bandwidth and therefore halves generation; budget the matched
>    2×32 GB kit if it ships with one stick.
>
> Vendors quietly swap RAM type, speed, and slot count between SKUs of the
> same model name (this page has already excluded several 32 GB-soldered
> traps: K16, SER9, EVO-X1).

## In service

| System | CPU / GPU | RAM | Role |
|---|---|---|---|
| ALLOY9-7940HS mini-PC (Shanghai Hongnian) | Ryzen 9 7940HS / 780M 12 CU | 2×32 GB DDR5-5600 SODIMM | **llm3** — fleet inference node |

## Candidates

### NIMO 17.3" laptop — Ryzen 9 8945HS, 64 GB, 2 TB

[Amazon listing](https://www.amazon.com/NIMO-Graphics-Fingerprint-AI-Powered-Business/dp/B0H339CXZ2/ref=sr_1_1)

Listed specs: AMD Ryzen 9 **8945HS** (Hawk Point — the 7940HS refresh: same
Zen 4 8C/16T, same 12-CU Radeon 780M, same DDR5-5600 controller; only the NPU
differs, which this stack doesn't use), 64 GB DDR5, 2 TB SSD, 17.3",
fingerprint reader, Windows 11. Surfaced via a "ryzen 9 7940hs laptop" search —
the listing itself is the 8945HS sibling.

**Expected inference speed: llm3-equivalent** (~23 t/s generation, prefill
llm3-class) — it is functionally the same silicon. The 17.3" chassis should
thermally behave more like the P16s (no throttling) than the 14" P14s.

Verify before buying / before trusting numbers:
- [ ] RAM is **2 × 32 GB dual-channel at 5600 MT/s** — single-DIMM or 4800 MT/s
  configs halve or cut bandwidth, and bandwidth is the generation hard cap.
- [ ] Rebuild per [RECREATE.md](RECREATE.md) (Ubuntu Server, kernel params, GTT
  carve); the Windows install is irrelevant to the role.
- [ ] Run the interleaved bench harness ([benchmarks/](benchmarks/)) before
  believing any throughput claim — fleet rule.

### llm3-equivalent platforms — 7840HS · 8845HS/8840HS · 8945HS · 8700G · Ryzen AI 9 HX 370/365

These land in llm3's measured class (~22–23 t/s generation, ~350–400 t/s
prefill on the 35B Q8_0) because they share the constraint that matters:
dual-channel DDR5-5600 (~89.6 GB/s). Phoenix/Hawk Point parts are the same
780M silicon as llm3; Strix Point (890M, 16 CU) is a **measured** tie — the
P16s benchmarked 304.3/22.2 vs llm3's 328.9/21.9. Only ≥64 GB systems listed.

#### Mini-PCs

| System | CPU | RAM | LLM notes |
|---|---|---|---|
| [Minisforum UM790 Pro](https://store.minisforum.com/products/minisforum-um790-pro) | 7940HS | 2×SODIMM DDR5-5600, to 64 GB | literally llm3's CPU in a nicer chassis (dual USB4, better cooling) |
| [Minisforum UM890 Pro](https://slickdeals.net/f/18696922-minisforum-um890-pro-mini-pc-barebone-ryzen-9-8945hs-2x-ddr5-2x-m-2-2280-gen4-usb4-oculink-2x2-5g-lan-449-f-s) | 8945HS | 2×SODIMM DDR5-5600, to 96 GB | Hawk Point refresh; 96 GB ceiling + OCuLink; barebone ~$449 |
| [Beelink SER7](https://us.amazon.com/Beelink-SER7-7840HS-Computer-Display/dp/B0CQT9N951) | 7840HS | 2×SODIMM DDR5-5600, to 64 GB | ships 32 GB — budget the 2×32 kit |
| [Beelink SER8](https://www.bee-link.com/products/beelink-ser8-8845hs) | 8845HS | 2×SODIMM DDR5-5600, to 64 GB | same class as SER7, newer bin |
| [GMKtec NucBox K8 Plus](https://www.gmktec.com/) | 8845HS | 2×SODIMM DDR5-5600, to 64 GB | cheapest of the Hawk Point minis (~$549 configured) |
| DIY AM5 build | **8700G** (desktop) | 2×DIMM, 64–128 GB+ | same 780M; desktop DDR5-6400+ OC would *beat* llm3's bandwidth — the only Phoenix-class path past 89.6 GB/s with ≥64 GB |

Excluded for <64 GB (same story as the K16): [Beelink SER9](https://wccftech.com/review/beelink-ser9-amd-ryzen-ai-9-hx-370-mini-pc-review-fastest-igpu-on-the-market/)
and [GMKtec EVO-X1](https://www.gmktec.com/products/amd-ryzen%e2%84%a2-ai-9-hx-370-evo-x1-ai-mini-pc) — HX 370 with soldered LPDDR5X-7500/8533
(120–136 GB/s, would beat llm3 on generation) but 32 GB non-upgradable ceilings.

#### Laptops

| System | CPU | RAM | LLM notes |
|---|---|---|---|
| [Framework Laptop 16](https://frame.work/) | 7840HS/7940HS | 2×SODIMM DDR5-5600, **to 96 GB** | orderable iGPU-only (no dGPU module); the best-aligned laptop here: llm3 silicon, 96 GB ceiling, repairable |
| [Framework Laptop 13 AMD](https://frame.work/laptop13) | 7840U | 2×SODIMM DDR5-5600, **to 96 GB** | U-series clocks trim prefill a bit; generation identical (same bus) |
| ThinkPad P14s Gen 6 AMD | AI 9 HX PRO 370 | 64 GB | the repo-root machine — all its measurements apply |
| ThinkPad P16s Gen 4 AMD | AI 9 HX PRO 370 | to 96 GB | **measured dead tie with llm3** (304.3/22.2 vs 328.9/21.9); 16" chassis never throttled |

**Reading the whole list:** every entry is the same ~22–23 t/s box in different
clothes. Differentiators are RAM ceiling (96 GB holds models llm3's 61 GB
cannot), chassis/thermals, and price — not speed. The only ways out of the
~22 t/s class are desktop memory OC (8700G) or a different memory architecture
entirely (soldered LPDDR5X at ≥64 GB, or Strix Halo's 256-bit bus — see
the fleet's Strix Halo node measures 64.7 t/s).

### The "holy grail" tier — 64 GB soldered LPDDR5X (beats llm3, still holds the 35B)

The one escape from the ~22–23 t/s class short of Strix Halo: same-generation
silicon on **LPDDR5X-7500 (~120 GB/s, +34% over llm3)** with a full 64 GB, so
generation rises to an estimated **~29–30 t/s** and the 35B Q8_0 + KV still
fits. Rare because 64 GB soldered configs barely exist (estimates, not
measured — bench before believing):

| System | CPU / GPU | RAM | Notes |
|---|---|---|---|
| [ASUS ProArt P16 **H7606WP-PB99T**](https://eshop.asus.com/us/90nb15k1-m00rp0-proart-p16-h7606-copilot-pc.html) | AI 9 HX 370 / 890M | **64 GB LPDDR5X-7500** | 16" 4K OLED + RTX 5070 you'd pay for but not use; ~$2.5K creator laptop. Older H7606WI 64 GB variants exist in some regions |
| [GPD Win Max 2 (2024)](https://www.amazon.com/GPD-Handheld-Controls-Keyboard-touchpad/dp/B0CZTPXC2Y) | 8840U / 780M | **64 GB LPDDR5X-7500** | a 10.1" handheld with llm3's exact GPU on a faster bus, plus OCuLink; the cheapest 64 GB LPDDR5X device known |

**SKU traps, per the warning at the top of this page:**
- ProArt P16: Best Buy's `H7606WP-P16.3KR95070` looks identical but is **32 GB**.
  Only `-PB99T` (and the 64 GB WI variants) qualify.
- Zenbook S16 (UM5606) does NOT qualify — caps at 32 GB despite sharing the
  HX 370 and the marketing.
- No 7735HS/Rembrandt grail exists: LPDDR5 devices of that generation cap at
  24–32 GB (Beelink EQR7: 24 GB; NucBox K16, ThinkPad X13 G3/Z13/Z16: 32 GB).

At these prices also compare Strix Halo (256-bit bus, measured 64.7 t/s on the
fleet's node) — the grail tier only wins when the machine must double as a
general-purpose laptop/handheld.

## Desktop AM5 + discrete GPU — the real escape from the class

⚠ **Everything in this section is extrapolated from the fleet's measured scaling
laws, not measured. Nothing here has run the harness.** Confidence is labelled
per claim. Two of the three numbers that matter came from this repo's own data;
the rest is first-principles arithmetic and two web-sourced bandwidth figures.

### The two scaling laws being extrapolated from

1. **Generation is purely bandwidth-bound** ([README.md](README.md) — "~22 t/s is
   the DDR5-5600 hard cap for this model regardless of tuning"; Q4_K_XL halving
   the model's bytes bought +15% TG and nothing on prefill,
   [../README.md](../README.md) §"What the quantisation data says").
2. **Prefill is compute-bound and scales with CU count** — the CU-scaled parity
   check against the 40-CU Strix Halo rig: 1150/473 ≈ 2.43 vs 40/16 = 2.5.

The bandwidth law is startlingly linear across the fleet's two real data points:

| node | theoretical BW | measured TG | t/s per GB/s |
|---|---|---|---|
| llm3 (780M, 2×DDR5-5600) | 89.6 GB/s | 23.0 | 0.257 |
| Strix Halo node (256-bit LPDDR5X) | 256 GB/s | 64.7 | 0.253 |

Slope ≈ **0.255 t/s per GB/s** on the 35B-A3B Q8_0 + MTP.

> **⚠ That law is only valid in the bandwidth-starved regime.** Both anchors are
> APUs whose iGPU is waiting on memory. Applied to a 960 GB/s dGPU it predicts
> 247 t/s, which batch-1 MoE decode on 96 CUs will never reach — you go latency-
> and kernel-launch-bound long before. Do not cite the slope above ~250 GB/s.

The prefill law is cross-checked against this repo's own UX number:
34.8k tokens / 97 s = 359 t/s, which lands on llm3's ~380 @8K.

### Ryzen 9 7950X3D, CPU-only — ruled out

**There is no usable GPU.** The 7950X3D's iGPU is 2 CU of RDNA 2 (`gfx1036`,
Raphael) — one-sixth of llm3's 12 CU, on an architecture with no WMMA/coopmat
path at all. So this is a CPU-backend extrapolation, which the fleet has never
measured.

Generation, from the slope above, but substituting *achievable* for theoretical
bandwidth — Zen 4 desktop cannot reach its peak: each CCD's GMI link caps read
bandwidth at ~64 GB/s, and measured whole-system read on a 7950X lands near
[~74.9 GB/s](https://www.club386.com/amd-ryzen-9-7950x-review-zen-master/) even
at DDR5-6000 ([per-CCD GMI
limit](https://linustechtips.com/topic/1579545-9950x-ccd-bandwidth-and-ram-performance/)):

| config | usable read BW | est. TG | confidence |
|---|---|---|---|
| DDR5-6000 EXPO, 2 DIMM, threads across both CCDs | ~75 GB/s | **~18–22 t/s** | medium |
| DDR5-5200 JEDEC (no EXPO) | ~68 GB/s | ~16–19 t/s | medium |
| pinned to the X3D CCD only (8 cores) | 64 GB/s cap | ~15–17 t/s | medium |
| 4 DIMMs for 192 GB (clocks fall to ~4000) | ~55 GB/s | ~12–15 t/s | low |

**A dead tie with llm3 at best** — the same tie llm3 fought the P16s and P14s to,
for the same reason. Dual-channel DDR5 is dual-channel DDR5.

Prefill is where it loses: 16 Zen 4 cores with double-pumped AVX-512 is ~2.5
TFLOPS FP32 peak, and llama.cpp's quantised GEMM realises 30–50% of that against
~6.6 GFLOP/token for a 3B-active MoE → **~130–180 t/s, central ~150** (low
confidence). That is ~2.5× slower than llm3, and it walks straight back into the
presenting problem of this whole repo: Qwen Code's ~41.6k startup prompt would
need **~4.6 minutes** of cold prefill, and [../README.md](../README.md) records
the client aborting mid-prefill at 3–4 minutes. On a CPU-only 7950X3D the
disk-cache fork stops being a latency nicety and becomes mandatory for the stack
to function at all.

**The 3D V-Cache is irrelevant here** — 128 MB of L3 against a ~3.2 GB
active-weight working set per token is a ~4% hit rate. The non-X3D 7950X would
measure equal or marginally *better* (higher sustained all-core clock on both
CCDs → better prefill) and avoids the asymmetric-CCD scheduling problem. Do not
pay the X3D premium for this workload.

Cost of the CPU-only version: ~200 W system draw against llm3's measured 50 W,
for the same tokens. The only reasons to want the box are RAM ceiling (2×48 GB
at 6000, or 2×64 GB at ~5600 — llm3 caps at 61 GiB usable) and the PCIe slot.

### Ryzen 9 7950X3D + Radeon RX 7900 XTX 24 GB — **recommended**

`gfx1100`, 96 CU RDNA 3, 24 GB GDDR6 @ 960 GB/s, 355 W TBP. This is the first
configuration on this page that beats the ~22 t/s class on *both* axes — and it
beats the Strix Halo node too.

**The binding constraint is 24 GiB of VRAM against a 35.2 GiB Q8_0.** KV is not
the problem: per [../README.md](../README.md) §"What the file actually contains",
of 41 blocks `qwen35moe.full_attention_interval = 4` means only ~10 carry
per-token KV — the other 31 are SSM layers with constant-size state. Measured
**10.65 KiB/token, 62.8 MiB floor, 2.7 GiB at the full 262,144 context.**

Weights are the problem, and [../README.md](../README.md) §5 already records the
fix: **`Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf` is 22.9 GB (21.3 GiB)** — the only
quant in the collection that fits. Q6_K_XL (30.4 GiB) and Q8_0 (35.2 GiB) do
not. **24 GB forces Q4**, and Q4_K_XL is the one measured as free:
`quant-q8-vs-q4kxl.tsv` gives prefill a wash (253–254 vs 257–259) and **+15%
generation**. It is also a UD quant, so attention and embeddings stay at high
precision — already the quality-optimal 24 GiB fit.

#### Optimum: Q4_K_XL, 100% VRAM-resident, 96K context, vision off

Draft unit: [proposed/llama-qwen3.6-35b-q4-dgpu.service](proposed/llama-qwen3.6-35b-q4-dgpu.service).

| item | size |
|---|---|
| `Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf` | 21.3 GiB |
| KV @ 98304 tokens, q8_0 (10.65 KiB/tok + 63 MiB floor) | ~1.06 GiB |
| MTP draft KV, q8_0 | ~0.1–0.2 GiB |
| compute buffer, `-b 8192 -ub 1024` | ~0.8–1.0 GiB |
| **total** | **~23.3 GiB** of ~23.5–24 usable |

96K covers the ~41.6k Qwen Code startup prompt with 2× headroom. The full 256K
needs ~2 GiB more than exists — reachable only with `-ctk q4_0 -ctv q4_0`
(halves KV to ~5.3 KiB/tok), and KV quant quality has never been A/B'd
([TODO.md](../TODO.md) item: `f16` vs `q8_0` still open), so do not spend the
only margin there first.

**Run the XTX headless and drive the monitor off the 7950X3D's 2-CU iGPU.** That
reclaims ~0.5–1 GiB, which in this budget is another 64K of context. The useless
iGPU finally has a job.

#### Why *not* the obvious hybrid — the counterintuitive finding

The instinct is to keep Q8_0 and 256K and push overflow experts to the CPU with
`--n-cpu-moe`. Against the laws above it is a bad trade. Shedding ~13 GiB puts
~61% of experts on the card and ~39% on the CPU:

| | Q8_0 hybrid (`--n-cpu-moe ~16`) | **Q4_K_XL fully resident** |
|---|---|---|
| decode | ~37 t/s | **~80–140 t/s** |
| prefill | **~340 t/s** | **~1500–2800 t/s** |

Decode improves because it is bandwidth-bound and 61% of reads move to a
960 GB/s bus. **Prefill does not move at all** — it is compute-bound, and
llama.cpp computes CPU-assigned experts on the CPU backend, so 39% of expert
FLOPs run on a core complex ~13× slower per FLOP than the card. You would spend
~$900 and land at ~340 t/s, *below* llm3's measured 380–400, leaving the
presenting problem of this repo untouched. Q4_K_XL fully resident fixes both
axes; the only cost is the quant, already measured free on throughput.

#### Expected numbers

| metric | llm3 (780M) | **7950X3D + 7900 XTX** | confidence |
|---|---|---|---|
| prefill | ~380–400 t/s | **~1500–2800 t/s** (central ~2000) | low — 8× CU extrapolation |
| 41.6k cold prefill | ~97–110 s | **~15–28 s** | low |
| generation (Q4 + MTP) | ~23 t/s | **~80–140 t/s** (central ~100) | low |
| context | 256K | 96K (256K with q4 KV) | derived from measured KV geometry |
| load power | ~50 W | **~500–550 W** | spec-based |

The CU-parity law was validated across a 2.5× CU gap; extrapolating across 8× is
a much bigger stretch. The ~100 t/s decode figure assumes ~30–40% of the linear
bandwidth prediction, which is where wide GPUs typically land at batch 1 — see
the regime warning above.

#### What transfers from the llm3/P14s corpus, and what is void

**Void — all of these were GTT-residency artifacts:**

| setting | why it no longer applies |
|---|---|
| `amd_iommu=off` (+26% on llm3) | that was GTT address translation for a system-RAM-resident model. Weights are in VRAM now — use **`iommu=pt`**, the normal dGPU setting. Do **not** carry `off` over blindly |
| `amdgpu.gttsize` / `ttm.pages_limit` / `ttm.page_pool_size` | no GTT residency. [TODO.md](../TODO.md) item 10 (gttsize sized for the old 60 GB box) becomes moot |
| BIOS UMA frame-buffer carve-out | no iGPU in the data path |
| Mesa version hunt + the 7 `GGML_VK_*` vars | different driver path entirely |
| `RADV_PERFTEST=nogttspill` | causes DeviceLost crashes on the APU ([../RADV-NOGTTSPILL.md](../RADV-NOGTTSPILL.md)); unneeded on a dGPU |
| DPM `high` vs `auto` forcing | dGPUs manage their own clocks; `cpu-performance.service` is not wanted |

**Transfers:** `-fa 1`; MTP self-speculation (+13%, and `--spec-draft-n-max` is a
measured no-op with `draft-mtp`); `--cache-ram` / `--cache-reuse 256`;
`--no-mmap --fit off -ngl 999`; the sampling block; the disk-cache fork (still
works, but at a 15–28 s cold prefill it drops from load-bearing to convenience).

**Re-test `-ub`.** The 2048 ≈ 1024 plateau ([README.md](README.md)) was found on
12 CUs. 96 CUs want wider batches to stay fed, and here `-ub` also trades
directly against VRAM for context. Genuinely open again.

#### The one experiment worth running first — ROCm

**ROCm is finally in play.** The "ROCm is a non-starter" finding in
[README.md](README.md) is specific: rocBLAS ships no `gfx1103` Tensile kernels.
The 7900 XTX is **`gfx1100` — a first-class rocBLAS/Tensile target**, needing no
`HSA_OVERRIDE_GFX_VERSION`. The repo's cross-check found ROCm ≈ Vulkan-RADV
(1017 vs 1023 t/s at 16k depth), but that was ROCm on `gfx1151`, a chip it
barely supports. On `gfx1100`, hipBLASLt plus real Tensile kernels and `rocWMMA`
flash attention are a legitimate arm.

> **Scope the existing ROCm conclusion to the APUs** so it does not go stale the
> way the `amd_iommu` row did.

#### Cost reality

~500–550 W under load against llm3's measured 50 W — **~10× the power for ~5× the
throughput**, so it is a worse machine per watt. Needs an 850 W PSU. Watch idle
draw too: RDNA 3 has a known high-idle-power issue (~15–40 W), which matters for
an always-on fleet node.

**2× 7900 XTX (48 GB)** would hold Q8_0 + full 256K + vision outright, but at
batch 1 llama.cpp's layer split serialises rather than doubling decode — 2× the
cost and 710 W of GPU for maybe +20% generation. Not worth it for this model;
the single-card Q4 config is the efficient point.

## Ruled out / adjacent

### Ryzen 7 7735HS / Radeon 680M systems

The 7735HS (Rembrandt-R: Zen 3+, RDNA 2 `gfx1035` 12 CU @ 2.2 GHz) was estimated
2026-09-02 at **~18–20 t/s generation** (high confidence — DDR5-4800 bandwidth
math) and **~250–320 t/s prefill** (low confidence — no coopmat path on RDNA 2,
lower clock) on the 35B-A3B Q8_0. A worse llm3 on both axes at SODIMM configs;
**estimate only, never measured** — run the interleaved harness before believing
anything.

#### Mini-PCs

| System | RAM | LLM notes |
|---|---|---|
| [Beelink SER6 MAX](https://www.amazon.com/Beelink-4-75GHz-PCIe4-0-Desktop-Computer/dp/B0BTH9J96D) | 2×SODIMM DDR5-4800, to 64 GB | the straight "cheaper llm3": ~18–20 t/s gen est. |
| [Minisforum UM773 Lite](https://www.minisforum.com/products/minisforum-um773-lite) | 2×SODIMM DDR5-4800, to 64 GB | same class as SER6 MAX |
| [GMKtec NucBox K2](https://www.gmktec.com/products/amd-ryzen%E2%84%A2-7-7735hs-mini-pc-nucbox-k2) | 2×SODIMM DDR5, to 64 GB | same class |
| [Minisforum HX77G](https://exegeek.com/products/minisforum-hx77g-amd-ryzen-7-7735hs) | SODIMM + discrete RX 6600M 8 GB | different class — dGPU too small for the 35B, iGPU notes don't apply |

#### Laptops

| System | RAM | LLM notes |
|---|---|---|
| [ASUS TUF A16](https://www.amazon.com/ASUS-Gaming-Laptop-7735HS-i7-13620H/dp/B0DZD3ZSYW) (16") | 64 GB DDR5 + discrete RX 7700S 8 GB | sold on the dGPU; for iGPU-style inference it degrades to the SODIMM 680M case |
| [Acer Nitro 16 AN16-41](https://www.acer.com/us-en/laptops/nitro/nitro-16-amd/pdp/NH.QKDAA.001) (16") | 2×SODIMM DDR5-4800, to 64 GB + RTX 4050–4070 | dGPU (6–8 GB) too small for the 35B; iGPU path = the SODIMM 680M case |
| [Lenovo IdeaPad Gaming 3 15ARH7](https://psref.lenovo.com/Product/IdeaPad/IdeaPad_Gaming_3_15ARH7) (15.6") | 2×SODIMM DDR5-4800, to 64 GB ([per Crucial](https://www.crucial.com/compatible-upgrade-for/lenovo/ideapad-gaming-3-15arh7)) + RTX 4050 | same story; cheapest of the three |

All three are dGPU gaming designs — none ships 64 GB stock except some TUF A16
SKUs, so budget the 2×32 GB kit. Excluded for <64 GB: ASUS ROG Zephyrus G14
GA402N (48 GB LPDDR5 max).

Fuller model list: [ultrabookreview 7735HS laptops](https://www.ultrabookreview.com/36004-amd-ryzen-7-laptops/).

Only systems supporting ≥64 GB RAM are listed (the 35B Q8_0 + 256K KV needs
~45 GiB GPU-addressable). Notably excluded: GMKtec NucBox K16 — its soldered
LPDDR5-6400 (102.4 GB/s) would actually beat llm3 on generation, but its 32 GB
non-upgradable ceiling caps it at Q4-class models.

**Takeaway:** at SODIMM DDR5-4800, nothing here beats a 780M box — every
qualifying 7735HS system is a cheaper, ~15–35% slower llm3.
