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
