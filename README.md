# p14 — running a local LLM coding stack on a ThinkPad P14s

**This repo is the research and operations record for a three-part project.** The other two parts
are code; this one is the notes, the measurements, the systemd unit and the test harnesses that
explain *why* that code looks the way it does. Read this first.

| repo | branch | what it holds |
|---|---|---|
| **[jstormes/qwen-code](https://github.com/jstormes/qwen-code)** | `p14/prefill-progress` | client side — warm the startup prompt at session init, and show real prefill progress instead of a spinner phrase. Fork of [QwenLM/qwen-code](https://github.com/QwenLM/qwen-code). |
| **[jstormes/llama.cpp](https://github.com/jstormes/llama.cpp)** | `p14/disk-prompt-cache` | server side — `--cache-disk-path`, a disk tier under the in-RAM prompt cache, plus a fix for slot restore losing its context checkpoints. Fork of [Nathanw1014/llama.cpp](https://github.com/Nathanw1014/llama.cpp), itself a Vulkan/Strix fork of [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp). |
| **this repo** | `main` | measurements, `llama.service`, probe harnesses, and the design docs behind both of the above |

**The three are one effort and should be read together.** Everything here exists to attack a
single cost: Qwen Code's ~41.6k-token startup prompt, which prefills at ~340–375 tok/s on this
hardware. That rate is a **ceiling, not a tuning problem** — a 9× smaller model measured the same,
so the only wins available are avoiding prefill rather than speeding it up. The client-side fork
moves the prefill off the critical path at launch; the server-side fork makes it survive the
`llama.service` restart that happens at every login. `-np 1` in the unit is what makes the two
safe together.

Start with [`TODO.md`](TODO.md) for current state and open items, and
[`disk-cache.md`](disk-cache.md) for the prompt-cache work.

---

## The host

> ## ⚠ 2026-08-22 — this is not the same p14, and one boot flag was worth 26%.
>
> **The original p14 died and its mainboard was replaced.** What carries the name "p14" today
> is a **new mainboard and a new power subsystem**, a newer BIOS, and the P16s' physical DIMMs
> moved across. Nothing in DMI or the hostname distinguishes them, so **every hardware-attributed
> number in this file predating 2026-08-22 was measured on hardware that no longer exists** —
> and which we now think was already failing.
>
> Two findings, both re-measured on the current machine:
>
> **1. `amd_iommu=off` had been silently removed, and it is worth ~26%.** It was taken out of
> GRUB on 2026-08-21 to unblock the NPU (since abandoned). The model is GTT-resident, so with
> the IOMMU on, every GPU access to 36 GiB of system RAM carries address translation. Restoring
> it: prefill **375 → 473 t/s**, generation **17.8 → 20.7**. Confirmed by a same-boot A/B.
> **If throughput here ever looks ~20% low, check `/proc/cmdline` before suspecting hardware.**
>
> **2. GPU DPM `high` — this file's biggest lever, "worth ~70%" — is worth 13% and costs more
> than it buys.** `auto` now ramps on its own to 418 t/s; `high` reaches 473 but loses 8.6% of
> generation for +29 W and a 95 °C package. **Stop running `set-dpm-high.sh`.** There is a good
> case the original presenting problem was a failing power subsystem rather than a
> misconfiguration.
>
> **The replacement mainboard is fine.** With the boot flag matched it lands within 3% of the
> P16s on both arms. An earlier version of this section claimed it was 23% slower and pointed
> at the heatsink; that was the IOMMU, and the retraction is kept visible in §3.
>
> Start at **"The 2026-08-22 re-measurement"** below. The P16s comparison is in **`p16s.md`**,
> and is cleaner than it was: the DIMMs in this machine are literally the ones that were in it.

Investigation date: **2026-08-06** (ongoing)
Last re-measured: **2026-08-22**

| | |
|---|---|
| Host | p14 — ThinkPad **P14s Gen 6 AMD** (`21RV000NUS`) |
| Mainboard | **replaced 2026-08 — new board and new power subsystem.** The original died |
| SoC | Ryzen AI 9 HX PRO 370 / Radeon 890M, gfx1150 *(new silicon instance, same part)* |
| RAM | **96 GB — 2× 48 GB Samsung `M425R6GA3PB0-CWMOD`, DDR5-5600 SODIMM, dual-rank, one per channel.** These are the **P16s' DIMMs, physically moved over**. 88 GB (83 GiB) visible to the OS after an 8 GB VRAM carve-out |
| GTT | 49152 MiB, from `amdgpu.gttsize=49152` + `ttm.pages_limit=12582912` on the kernel command line — **sized for the old 60 GB box and now the binding limit**, see TODO item 10 |
| BIOS | **R2XET40W (1.20)**, 2026-05-26 *(was R2XET39W 1.19)* |
| OS | Ubuntu 26.04 LTS, kernel 7.0.0-30-generic |

Model: Qwen3.6-35B-A3B Q8_0 + mmproj-BF16, served by `llama.service` (user unit) on
`127.0.0.1:8080`

> **The RAM question in `p16s.md` is settled, and settled harder than expected.** That file
> warned that p14's memory *type* was never recorded — only "60 GB" — and that if p14 were
> soldered LPDDR5x-7500 (~120 GB/s), the P16s would have had *less* bandwidth, skewing the
> comparison. It is moot: the DIMMs were **moved from the P16s into this machine**, so the
> two boxes now share not merely a bandwidth class but the same physical parts —
> `dmidecode -t 17` reports `Form Factor: SODIMM`, DDR5-5600, dual-rank, on both channels.
> p14 has SODIMM slots and is therefore not soldered. **Drop the bandwidth asterisk.**

Reference documentation lives on **refhost** — a separate machine on the local network that holds
the install guide and the baseline benchmark data this work is measured against. Referred to by
placeholder throughout; paths are `refhost:~/p14s-setup/P14S-NATIVE-INSTALL.md` and
`refhost:~/p14s-setup/toolbox-raw/*.tsv`.

---

## The 2026-08-22 re-measurement

The mainboard swap makes every earlier number a measurement of hardware that no longer
exists. This section is what the machine actually does now.

**Protocol.** `bench-dpm.sh`, the same 18k-token nonce-prefixed cold prompt as
`bench-local.sh`, **4 fully interleaved rounds** of DPM `auto` / DPM `high`, one server
process throughout, GPU telemetry sampled at 1 Hz. Round 1 dropped per the rep-order rule.
CPU governor left at `powersave` — closed 2026-08-21 as worth ~0%. Raw data:
`dpm-results.tsv`.

Server is `llama-test.service` (the `p14/disk-prompt-cache` fork). **This is the same server
the P16s numbers were taken against** — `llama.service` never started on 2026-08-21, verified
in the journal — so `p16s-bench-results.tsv` and `dpm-results.tsv` are directly comparable.

### Result — steady state, round 1 dropped, n=3

Current configuration, i.e. `amd_iommu=off` restored (`dpm-results-iommu-off.tsv`):

| arm | PP | TG | sclk | W | °C |
|---|---|---|---|---|---|
| `dpm-auto` (boot default) | 418.1 | **22.59** | 1922 | **24.0** | **70.7** |
| `dpm-high` | **473.1** | 20.65 | 2892 | 53.1 | 94.7 |

**DPM `high` is +13.2% on prefill, −8.6% on generation, for +121% power and +24 °C.**

For the record, the same benchmark taken earlier the same day *before* `amd_iommu=off` was
restored (`dpm-results.tsv`) — this is the confound, not a configuration anyone should run:

| arm | PP | TG | sclk | W | °C |
|---|---|---|---|---|---|
| `dpm-auto`, IOMMU on | 350.2 | 19.67 | 2169 | 24.0 | 67.3 |
| `dpm-high`, IOMMU on | 374.9 | 17.81 | 2900 | 46.7 | 84.7 |

### 1. The ~70% DPM lever is gone, and it was probably never a tuning win

This document's central claim is that `power_dpm_force_performance_level=auto` left the GPU
"at **~1150 MHz drawing 13 W**" under 100% load, and that forcing `high` recovered ~70%. On
this board `auto` does what `auto` is supposed to do: it ramps to 2137–2480 MHz at 24–28 W
under load, and prefill runs at 350–372 t/s without anyone touching sysfs.

That is now **two healthy machines against one sick one**:

| board | DPM `auto` under load | PP at `auto` |
|---|---|---|
| original p14 mainboard (since died) | **~1150 MHz, 13 W** | 232 |
| P16s, 2026-08-21 | ~2000–2500 MHz, 24–32 W | 436 |
| replacement p14 mainboard, 2026-08-22 | 1914–2138 MHz, 24–26 W | **417–442** |

> **Hypothesis, clearly labelled as one: the presenting problem was a failing power
> subsystem, not a misconfiguration.** A GPU that will not leave ~1150 MHz / 13 W under
> sustained 100% load, on a board that later died outright, looks much more like early
> hardware failure than like a driver default. Every board we have measured that was *not*
> about to fail ramps on its own. On that reading, `set-dpm-high.sh` was a workaround that
> forced a sick VRM to deliver power it would not deliver voluntarily — which is exactly why
> it was worth ~70% then and ~7% now.
>
> This cannot be proven: the evidence died with the board. But it is the reading most
> consistent with what three boards have done, and it should be the default assumption until
> something contradicts it.

**Operationally: stop running `set-dpm-high.sh`.** On this board, with `amd_iommu=off`
restored, it buys **13% of prefill and costs 8.6% of generation**, for 29 W and 24 °C — and it
runs the package at 95 °C. For interactive coding, where generation is what you sit and watch
and prefill is mostly cache hits, that is a net loss. Worth it only for a long batch prefill.
See TODO item 2.

### 2. The cause: `amd_iommu=off` had been removed — confirmed by A/B

**One kernel boot parameter accounts for essentially all of it.**

`npu-after-reboot.sh` records that `amd_iommu=off` was removed from `/etc/default/grub` at
**13:13 on 2026-08-21** to unblock the NPU — XDNA2 needs SVA, SVA needs the IOMMU, and with
`amd_iommu=off` there were zero IOMMU groups. The box rebooted at 13:16 and the IOMMU stayed
on until 2026-08-22.

It was restored and the machine rebooted. Same board, same DIMMs, same server, same harness,
same power state — **the only difference is the boot flag.** Steady state, round 1 dropped,
n=3; raw data `dpm-results-iommu-off.tsv`:

| arm | metric | IOMMU **on** | IOMMU **off** | gain | P16s | vs P16s |
|---|---|---|---|---|---|---|
| `auto` | PP | 350.2 | **418.1** | **+19.4%** | 429.7 | −2.7% |
| | TG | 19.67 | **22.59** | **+14.9%** | 22.67 | −0.3% |
| | sclk | 2169 MHz | 1922 MHz | −11.4% | 1971 MHz | −2.5% |
| | W | 24.0 | 24.0 | 0.0% | 24.0 | 0.0% |
| `high` | PP | 374.9 | **473.1** | **+26.2%** | 487.7 | −3.0% |
| | TG | 17.81 | **20.65** | **+16.0%** | 21.68 | −4.7% |
| | sclk | 2900 MHz | 2892 MHz | −0.3% | 2899 MHz | −0.2% |
| | W | 46.7 | **53.1** | **+13.7%** | 54.8 | −3.1% |

**+19–26% prefill and +15–16% generation from one boot parameter.**

**Why it costs so much here:** the model is **GTT-resident** — 36 GiB of system RAM reached
through the GART — so with the IOMMU on, *every* GPU access to it carries address translation.
This file's own kyuz0 cross-check rates `amd_iommu=off` at 5–12% generally; on a workload that
lives entirely in GTT it is worth double that.

Two details confirm the *mechanism*, not just the effect:

1. **Power tracks throughput.** At `dpm-high` the GPU now draws **53.1 W where it drew 46.7 W
   at the same 2900 MHz**, matching the P16s' 54.8 W. The low power was the GPU stalling on
   translation, not a cap being imposed on it.
2. **At `auto` the IOMMU-off run is faster at a *lower* clock** — 1922 vs 2169 MHz, and
   +19.4% prefill. With the IOMMU on the GPU was clocking *higher* to compensate and still
   losing.

### 3. The replacement mainboard is exonerated

With the boot parameter matched, the p14 lands **within 3% of the P16s on both arms** — inside
the run-to-run spread, and the small residual is the 14" chassis running 3 °C hotter at
`high` (94.7 vs 91.5 °C).

There is no hardware deficit. The board swap left the machine **better untuned and equal
tuned**: as-found prefill 232 → 418 t/s, best-case 483 → 473.

> **Retracted, in order, so the wrong turns are on the record:**
>
> 1. *"The board is thermally limited — probably heatsink seating from the repair."* Disproved
>    by the DPM `auto` row: identical power, higher clock, cooler, still slower.
> 2. *"The board is 23% slower at the top end."* Confounded — it compared a P16s measured with
>    `amd_iommu=off` against a p14 measured with the IOMMU on. **This is the one that mattered,
>    and it was heading toward a warranty claim against a healthy board.**
> 3. *"The P16s showed the same signature under lemonade contention"* (`lemonade-deb-interleaved.tsv`,
>    360–385 PP at 2900 MHz). Wrong mechanism, right observation: that file was written at
>    14:03 on 2026-08-21, i.e. **after** the 13:16 reboot, so those runs had the IOMMU on too.
>    It is not contention — it is the same boot flag, and it is a fourth data point for it.
>
> The common thread: the "memory stall" reading of the *signature* was correct every time.
> What was wrong was attributing it to the hardware without checking that the software
> configuration had not moved underneath the comparison.

**The rule this earns:** when throughput on this box looks ~20% low, **check `/proc/cmdline`
before suspecting hardware.** The README's "Ruled out" table said `amd_iommu=off` was "already
set"; it had not been true for a day, and nothing in DMI, the hostname, or the benchmark output
says otherwise.

### 4. Memory tuning — what moves the needle and what doesn't

Two levers were tested on 2026-08-22 beyond the IOMMU. **One is everything; the other is
nothing.**

| lever | effect | verdict |
|---|---|---|
| `amd_iommu=off` | **+19–26% PP, +15–16% TG** | the whole ballgame — §2 |
| BIOS VRAM carve-out, 8 GB → 1 GB | +0.5–1.5% PP, +0.5–2.1% TG — inside noise | **no effect; keep it small** |

**The carve-out result is worth stating as a negative, because the hypothesis was reasonable
and wrong.** With an 8 GB carve-out, VRAM ran 100% full (8157/8192 MiB) and ~36 GiB of the
model spilled into GTT. VRAM is reached through the local aperture, GTT through the GART — and
having just measured that adding a translation layer to GTT cost 26%, moving *more* of the
model into VRAM looked like the obvious next win.

It isn't. Tested in the opposite direction — carve-out cut to 1 GB, so ~7 GiB *more* of the
model went to GTT — **nothing changed**, matched protocol, `dpm-results-uma1g.tsv`:

| arm | metric | UMA 8 GB | UMA 1 GB | delta |
|---|---|---|---|---|
| `auto` | PP | 418.1 | 420.3 | +0.5% |
| | TG | 22.59 | 22.70 | +0.5% |
| `high` | PP | 473.1 | 480.4 | +1.5% |
| | TG | 20.65 | 21.09 | +2.1% |
| | °C | 94.7 | 89.7 | −5.3% |

Every PP/TG delta is inside the run-to-run spread (sd ~5 on PP). *(The −5 °C is the one figure
outside obvious noise and is **not** attributed — thermal history across two separate boots is
a likelier cause than the carve-out.)*

In hindsight it fits: with `amd_iommu=off`, the remaining GART translation runs on the GPU's
own page tables with large fragments, and VRAM and GTT are **the same physical DDR5 at the same
bandwidth**. The IOMMU was an extra layer on top of that; the GART itself is cheap.

> **Set the carve-out to minimum.** Same throughput, and **7 GB handed back to the OS**
> (83 → 90 GiB usable). Do not spend another BIOS trip and reboot testing this.

**What the quantisation data says about where to look next.** `quant-q8-vs-q4kxl.tsv`, steady
state: Q4_K_XL vs Q8_0 is **a wash on prefill** (253–254 vs 257–259) but **+15% on generation**
(19.6–21.0 vs 17.3–17.7). Halving the model's bytes did nothing for PP and helped TG — so on
this box **prefill is compute-bound and generation is bandwidth-bound.** Memory-side tuning
will move TG and largely leave PP alone; expect prefill wins to come from batch/kernel work
instead.

Untested and still open: `-ub`/`-b` batch geometry (the live prefill knob, since prefill is
compute-bound), KV cache `f16` vs `q8_0`, and THP (`madvise` today, `AnonHugePages: 0`, and the
weights live in device memory so it probably cannot help). `amdgpu.vm_fragment_size` is `-1`
(auto, already picks the largest supported fragment) — low value, costs a reboot.

---

## Presenting problem

Qwen Code got no response from the local model. The server was healthy the whole time —
the real fault was throughput. Prefill was running at roughly **half** the documented
figure, so a ~34.5k-token Qwen Code prompt needed 3–4 minutes before the first token, and
the client gave up mid-prefill.

Server-side signature of the abort (`journalctl --user -u llama.service`):

```
prompt processing, n_tokens = 9451, progress = 0.99, t = 70.39 s / 134.27 tokens per second
W srv stop: cancel task, id_task = 370
slot release: id 0 | task 370 | stop processing: n_tokens = 34539
```

Corroborated in `~/.qwen/usage_record.jsonl`, where those sessions recorded a request with
`inputTokens: 0, outputTokens: 0` and 20–150 s of latency — no tokens ever billed. The one
session that *did* work had `cachedTokens: 32768` of `34811`, i.e. it only survived because
the prompt cache spared it a cold prefill.

## Baseline being measured against

`refhost:~/p14s-setup/toolbox-raw/p14s-toolbox-sys.tsv`, n=12 over two interleaved
blocks, 18k-token cold prompt:

| metric | baseline |
|---|---|
| PP (prefill) | 485–493 t/s |
| TG (generation) | 21.5 t/s |
| GPU | 2900 MHz, 58–62 W, 87–93 °C |

---

## Result

| stage | PP t/s | TG t/s |
|---|---|---|
| as found | 225–233 | 16.3 |
| + documented §9c server flags | 233–240 | 16.2–17.7 |
| + GPU DPM `high` | 391–405 | 19.9–21.9 |
| + toolbox **wrapper** (bundled Mesa 26.3.0) — *current config* | **425–433** | **20.0–22.3** |
| + Mesa **26.1.6** instead — *tested, not yet adopted* | 433–446 | 19.7–22.0 |
| *baseline* | *485–493* | *21.5* |

**Prefill up ~85% as configured, ~95% with the 26.1.6 driver. Generation fully recovered**
(22.3 vs 21.5 baseline).

Attribution:

| cause | share of the gain |
|---|---|
| GPU DPM `high` | ~70% |
| Vulkan driver version (via the wrapper) | ~8% |
| the documented server flags | ~3% |
| Mesa 26.1.6 over the bundled 26.3.0 | ~3% more, available |

---

## The two things that actually mattered *(on the board that died)*

> **Both of these are history as of 2026-08-22.** §1 below is worth ~7%, not ~70%, on the
> replacement mainboard, and costs 9.5% of generation to get it — see "The 2026-08-22
> re-measurement". §2 still holds: the driver the server runs against is still the driver
> the server runs against. Kept in full because the *reasoning* is what explains the shape of
> `llama.service`, and because §1 is the best surviving evidence for the failing-hardware
> reading.

### 1. GPU DPM level — worth ~70% ~~on this box~~ *on the original mainboard only*

As found, `power_dpm_force_performance_level` was `auto`. Under 100% GPU load the card sat
at **~1150 MHz drawing 13 W**, against the 2900 MHz / 58–62 W the baseline recorded. The
throughput ratio tracked the clock ratio almost exactly (1150/2500 ≈ 0.46; 235/489 ≈ 0.48).

```bash
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
```

> ⚠ **This is a runtime write and reverts to `auto` on reboot.** It is the single most
> fragile part of this setup — ~70% of the gain disappears at next boot. The documented
> install persists it via a system unit (`cpu-performance.service`, §9b) which is **not**
> installed on p14, because p14 deliberately runs a *user* unit tied to the graphical
> session (GPU access comes from the logind ACL, not group membership).
>
> **If throughput ever looks halved again, check this value first.**

> **Revised 2026-08-22.** None of the paragraph above is actionable on the current board.
> `auto` ramps by itself; `high` buys 7% of prefill and loses 9.5% of generation. The
> fragility that made this "the single most fragile part of this setup" is gone with the
> board it belonged to — and if throughput ever *does* look halved again, the first thing to
> check is no longer this sysfs value but **whether the hardware is failing**, because that
> is what halved it last time.

Note that `high` also pins the clock at 2900 MHz *at idle*, so idle GPU power is higher
than with `auto`. On battery that is a real cost.

### 2. Launch via the wrapper, not the raw binary — worth ~8%

> **§7 of `P14S-NATIVE-INSTALL.md` is wrong about this.** It says to always launch
> `vulkan/bin/llama-server` with `LD_LIBRARY_PATH` set to `vulkan/bin`. That silently
> bypasses the launcher and costs ~8%.

`/opt/llama/strix-toolbox/vulkan/llama-server` is a wrapper around
`vulkan/bin/llama-server`. It does two things the raw binary does not get:

- sets `VK_ICD_FILENAMES` / `VK_DRIVER_FILES` to the toolbox's **bundled Mesa 26.3.0**,
  and puts `driver/` ahead of `bin/` on `LD_LIBRARY_PATH` — **this is the part that
  matters**, see the Mesa section below
- exports seven `GGML_VK_*` performance vars — `MMID_ROWLISTS`, `MMID_SMALLN`,
  `MMID_BM64`, `MMID_WAVE32`, `MMID_F16B`, `MMID_M128`, `FA_WAVE32`. Measured worth ~0% on
  build 458, which already defaults them on; they matter only for older payloads.

Without it the server runs against whatever system Mesa is installed. Verify it took:

```bash
tr '\0' '\n' < /proc/$(systemctl --user show -p MainPID --value llama.service)/environ \
  | grep -E 'GGML_VK|VK_ICD'      # expect 7 GGML_VK vars + VK_ICD_FILENAMES
```

---

## Ruled out — do not retest

| hypothesis | result |
|---|---|
| **llama.cpp build version** | 319/54d76da (the baseline's build) gives 425–447 vs 425–433 for the current 458/7a57bed. Within noise at n=4. v0.2 is installed alongside at `/opt/llama/strix-toolbox-v0.2` if you want to re-run it. |
| **AC vs battery** | Identical. On AC: 392–409 PP at 49–58 W / 68–89 °C, matching the baseline's 58–62 W / 87–93 °C envelope. *(Original board. The replacement never exceeds ~47 W, so this envelope no longer describes the machine — but the AC-vs-battery conclusion itself has not been re-tested.)* |
| **`--mmproj`** | Removing the vision projector gives 383–388 — no better. Kept. |
| **`platform_profile`** | `p14s-platform-profile.tsv` shows low-power 480 vs performance 486. Within noise. Also managed dynamically by `power-profiles-daemon`. **Re-tested 2026-08-22 on the replacement mainboard and it still holds: `balanced` 375.2 vs `performance` 373.8, −0.4%.** Worth re-running rather than inheriting, because the new board is 23% slower at the same clock and a cTDP change was the obvious suspect — it isn't one. `prof-results.tsv`, harness `bench-prof.sh`. |
| **Server flags alone** | ~3%. Necessary but nowhere near sufficient. |

## Mesa driver version — tested, worth ~10% end to end

The Vulkan driver matters, and it is what the wrapper's gain was actually made of.
Isolating the wrapper's two effects (7 env vars vs. driver swap), with everything else
held constant on build 458 + DPM `high` + AC:

| driver | PP t/s (mean) |
|---|---|
| system Mesa **26.0.3** | 400–407 (404) |
| toolbox bundled **26.3.0** | 425–433 (429) — *currently in use* |
| kisak **26.1.6** | **433–446 (442)** — best |

> ⚠ **Superseded 2026-08-07.** A larger interleaved run under the doc's own power state
> (DPM `high` **and** `performance` governor), with the first rep after each server start
> discarded, measured bundled 26.3.0 at **483.2** and kisak 26.1.6 at **483.5** — a +0.4%
> difference, i.e. nothing. The ~3% edge below was measurement conditions. Only 26.0.3 is
> genuinely slow. See "The last ~10% — closed" for the full 2×2.

- **The `GGML_VK_*` env vars are worth ~0%** on build 458. Setting all seven explicitly
  against the system driver moved 392–409 → 400–407, i.e. noise. The wrapper's own comment
  explains why: the binaries default them all on since fork commit `0b29b30`. **The
  wrapper's ~8% was almost entirely the driver swap.**
- **26.1.x beats both neighbours**, which vindicates the doc's §4 pin of 26.1.5. Newer is
  not monotonically better — 26.3.0 is measurably slower than 26.1.6.

26.1.5 itself is not published for resolute; kisak ships **26.1.6**, the same minor series.

### Tested without touching the system graphics stack

No PPA was added and system Mesa is untouched. The driver was extracted from the .deb into
a private directory and selected per-process — the same mechanism the toolbox wrapper uses:

```bash
curl -LO https://ppa.launchpadcontent.net/kisak/kisak-mesa/ubuntu/pool/main/m/mesa/mesa-vulkan-drivers_26.1.6~kisak1~r_amd64.deb
dpkg-deb -x mesa-vulkan-drivers_26.1.6~kisak1~r_amd64.deb kisak/
# then point an ICD manifest's library_path at the absolute path of
# kisak/usr/lib/x86_64-linux-gnu/libvulkan_radeon.so and export
# VK_ICD_FILENAMES / VK_DRIVER_FILES at that manifest.
```

All dependencies resolved against the stock system, and the GPU enumerated normally
(`Vulkan0: AMD Radeon 890M Graphics (RADV STRIX1)`).

> **Not currently active.** The test copy lived in a scratch directory, so the unit was
> restored to the bundled 26.3.0 driver rather than left pointing at a path that will be
> cleaned up. To adopt 26.1.6, copy it somewhere durable (e.g.
> `/opt/llama/mesa-26.1.6/`) and set `VK_ICD_FILENAMES` in the unit. That is worth ~3%
> over the current config and needs no system-wide change.

## Cross-check against kyuz0/amd-strix-halo-toolboxes

Independent benchmark corpus for Strix Halo:
<https://github.com/kyuz0/amd-strix-halo-toolboxes>. Checked for anything we were missing.
**Net result: no new lever — but it corroborates the build choice and gives a sanity check
on absolute performance.**

⚠ **Their rig is not ours.** kyuz0 benchmarks a **Radeon 8060S (RADV STRIX_HALO, gfx1151,
40 CU)**; p14 is a **Radeon 890M (RADV STRIX1, gfx1150, 16 CU)** — 2.5× the compute units.
Absolute numbers do not transfer. Their measurements are also `llama-bench pp2048 @ depth`
(instantaneous rate at a given KV depth) against our full-prefill average over 0→18k, and
their model is `UD-Q8_K_XL` vs our `Q8_0`.

| finding | applies to p14? |
|---|---|
| `amd_iommu=off` beats `iommu=pt`, worth 5–12% | **Confirmed, and worth far more here — ~26%.** Their default-profile → perf+iommu-off delta is 909→1024 t/s at 16k depth, but that arm bundles the platform profile too. ⚠ **This row used to read "already set" and that went stale without warning** — it was removed from GRUB on 2026-08-21 for the NPU and cost 26% for a day. **Verify against `/proc/cmdline`, never against this table.** See "The 2026-08-22 re-measurement" §2. |
| `vulkan-amdvlk` billed in the README as "fastest backend" | **No — much slower for this workload.** Same model, same flags, d32768: AMDVLK **307 t/s** vs RADV **683 t/s** prefill. Ruled out. Their "fastest" claim does not hold for MoE prefill. |
| ROCm backends | **No meaningful prefill win.** rocm-7.14 gives 1017 t/s at 16k depth vs vulkan-radv-performance's 1023 — a tie. Their ROCm images also target gfx1151. |
| their `vulkan-radv-performance` toolbox | **This is the fork we already run.** `Dockerfile.vulkan-radv-performance` builds from `Nathanw1014/llama.cpp`, branch `strix-halo-vulkan` — the same source as `/opt/llama/strix-toolbox`. Independent corroboration that it is the fastest known Vulkan build for this silicon. |
| hidden RADV env tuning | **None.** Their images install stock distro `mesa-vulkan-drivers` with no `RADV_PERFTEST` or equivalent. The only env vars in play are the seven `GGML_VK_*` from the fork, which we already have (and which measure as ~0% on build 458). |

### Scale check — p14 is performing as its silicon predicts

Averaging their same-fork prefill curve over 0→16k depth (1299 t/s at depth 0, 1023 at 16k)
gives roughly **1150 t/s** on 40 CU. p14 measures **442 t/s** at 18k on 16 CU.

    1150 / 442 ≈ 2.6      vs      40 CU / 16 CU = 2.5

**p14 is at CU-scaled parity with the reference Strix Halo rig running the same build.**
Given the methodology differences above this is indicative rather than rigorous, but it is
strong enough to reframe the open question below.

> **⚠ No longer true on the replacement mainboard — 2026-08-22.** That parity argument was
> built on 442 t/s. The current board measures **375 t/s** at `dpm-high`:
>
>     1150 / 375 ≈ 3.07      vs      40 CU / 16 CU = 2.5
>
> **Still holds on the replacement mainboard — 2026-08-22.** With `amd_iommu=off` restored,
> `dpm-high` measures **473 t/s**:
>
>     1150 / 473 ≈ 2.43      vs      40 CU / 16 CU = 2.5
>
> i.e. CU-scaled parity, same as the original board. (Measured *without* the flag it reads 375
> and ~19% below parity — which is how a boot parameter briefly looked like a hardware fault.
> See §2 of the re-measurement.)

## The last ~10% — closed 2026-08-07, it reproduces

**p14 hits the 489 baseline.** Measured with a reconstruction of the missing `llama-variant`
protocol: §9c flags verbatim, 18k nonce-prefixed cold prompt, 2 interleaved blocks,
`toolbox build × Vulkan driver` as a 2×2, plus the production driver as a fifth arm.

Steady state (see the rep-order note below):

| arm | build | driver | PP | sd |
|---|---|---|---|---|
| `458-sys` | 458 | system 26.0.3 | 417.6 | 3.8 |
| `319-sys` | **319** | system 26.0.3 | 426.5 | 3.9 |
| `319-kisak` | **319** | kisak 26.1.6 | 476.7 | 2.5 |
| `458-kisak` | 458 | kisak 26.1.6 | 483.5 | 5.1 |
| `458-bundled` | 458 | bundled 26.3.0 — **current config** | **483.2** | 6.6 |

Pooled modern-driver arms: **481.7 ± 5.6, i.e. −1.5% from the documented 489 ± 2.4.**

Three conclusions, two of which contradict what this file used to say:

- **The llama.cpp build is irrelevant.** 319 (the baseline's build) and 458 (current) are
  indistinguishable — 426.5 vs 417.6 on old Mesa, 476.7 vs 483.5 on kisak. The differences
  point in opposite directions and sit inside the noise. Nothing was lost between builds.
- **Only Mesa 26.0.3 is slow.** 26.1.6 and 26.3.0 are equivalent (483.5 vs 483.2, +0.4%).
  The earlier claim that 26.1.6 beats the bundled 26.3.0 by ~3% **does not hold up** — that
  gap was measurement conditions, not driver. There is nothing to adopt; the config already
  in use is as fast as anything tested.
- **The gap was the measurement, not the machine.** The earlier 429 for this exact
  configuration versus 483 here differs in two controllable ways: the CPU governor was on
  `powersave` (this run used `performance`, which the doc's §15 specifies and p14 never
  applied), and rep-order contamination, below.

### Rep-order effect — worth knowing before running this harness again

The first request after a server start is systematically slow, presumably GPU clock ramp.
Pooled across every arm:

| rep within block | n | mean PP |
|---|---|---|
| 1 | 12 | 447.3 |
| 2 | 12 | 459.4 |
| 3 | 12 | 464.2 |

At n=3 per block that first rep drags the mean down ~4%; the doc's n=11–12 dilutes it to
almost nothing. **Discard the first rep after each server start**, or use a large n. All
figures in the table above have rep 1 dropped.

### Resolved 2026-08-07 — the 489 was measured on a configuration p14 has never run

`llama-variant` **does not exist** on refhost or on p14, so it could not be read. But the
doc it belongs to answers all three questions directly, and the gap turns out to be
explained without either number being wrong.

**Same machine, different everything else.** `P14S-NATIVE-INSTALL.md` states the numbers
were "measured on this exact machine on 2026-08-04", model `21RV000NUS` — and this box *is*
a `21RV000NUS`. But four things differ:

| | 489 baseline (2026-08-04) | p14 now |
|---|---|---|
| llama.cpp toolbox build | **319 (54d76da), toolbox v0.2** | **458 (7a57bed)** |
| system Mesa | **kisak `26.1.5~kisak1~r`** | stock Ubuntu **26.0.3** |
| BIOS | `R2XET33W (1.13)` | `R2XET39W (1.19)` |
| launch | `vulkan/bin/llama-server` + system Mesa | wrapper + bundled 26.3.0 |

- **Wrapper or raw binary?** Raw binary, deliberately: §7 says *"Use system Mesa, not the
  toolbox's bundled driver"* because on that rig system Mesa was the pinned 26.1.5 and beat
  the bundled 26.3.0-devel. The arm name `toolbox-sys` means exactly that. See `TODO.md`
  item 3 — this reverses what that item used to claim.
- **Which Mesa?** kisak **26.1.5**, never installed on p14. p14's fastest tested driver was
  26.1.6 at 442 — adjacent, but not the pinned build, and only ever run from a scratch dir.
- **Same machine?** Same model and, per the doc, the same unit — but on an older BIOS and,
  critically, an older llama.cpp: **build 319 versus 458.**

**So the comparison was never like-for-like.** The baseline's exact arm — toolbox build 319
against kisak Mesa 26.1.5 — has not been reproduced on p14 even once. Neither figure needs
"explaining"; they are different configurations. Reproducing 489 would mean pinning both
the build and the driver, which is a bigger change than the ~10% is worth.

**A caveat on the archive.** Every file in `toolbox-raw/` shares the mtime
`2026-08-05 14:11` — a day *after* the measurements — so refhost holds a copied bundle, not
the original working tree, which is why `llama-variant` is missing. The doc also states
"No sshd — this is a laptop, everything below is run locally", which contradicts
`bench-host.sh` driving arms with `ssh "$HOST" "llama-variant $arm"`. That script cannot
have produced this TSV against the machine as documented. Treat `bench-host.sh` as
indicative of the *protocol* (nonce-prefixed 18k prompt, interleaved blocks) rather than as
the exact harness that generated the numbers.

Minor: the baseline is n=**11**, not 12, and the 489 figure is the `balanced` platform
profile; the doc's own recommendation is `low-power` at **478**.

---

## Unrelated findings

- **Qwen Code needs adequate `max_tokens`.** Qwen3.6 is a thinking model and the server
  runs `reasoning_format: deepseek`, so the `<think>` block is stripped out of `content`
  and returned separately as `reasoning_content`. With a small budget, generation dies
  mid-thought and `content` comes back as `""` with `finish_reason: "length"` — the client
  renders nothing. Verified: `max_tokens: 32` → empty; `max_tokens: 512` → `"PONG"`.
  `--reasoning-budget 2048` (now set) bounds runaway thinking but cannot rescue a tiny
  budget. Clients that only read `choices[0].message.content` will show blank whenever the
  model is mid-think.
- **`--cache-ram 8192`** is now set, and as of 2026-08-07 this is **measured, not assumed**:
  a second Qwen Code launch against an already-running server reuses its full ~34.8k
  opening prompt with *zero* prefill — no `prompt processing` line in the journal at all.
  See "Persisting the prompt cache across restarts" below.
- **`--no-mmap` is deprecated** in build 458: *"use `--load-mode mmap` instead."* Still
  honored, just warns.
- **CORS is open** (`*`) with no API key. Loopback-bound, so low risk, but any local
  process or browser page can reach the API.
- Early in the session four start failures appeared in the journal — `couldn't bind HTTP
  server socket, port: 8080`, restart counter to 3. A previous instance still held the
  port; it self-resolved. Not related to performance.

---

## Persisting the prompt cache across restarts — investigated 2026-08-07

**Question:** can Qwen Code's opening prompt be kept warm across a `llama.service` restart,
so the first launch after a login skips its cold prefill?

**Answer: yes, since 2026-08-11 — but not via this API, and the diagnosis below is wrong.**

Two things were established on 2026-08-11 and supersede this whole section. Details and
evidence in `disk-cache.md` (§"Step 2" and §"Implemented").

1. **Slot restore failed because it never repopulated `prompt.checkpoints`**, not because the
   prefix matcher ignored the restored state. On this hybrid/recurrent model
   `llama_memory_seq_pos_min()` reports the recurrent-state position rather than 0, so the
   server needs a context checkpoint to resume from on essentially every request. The restore
   handler repopulated only the token list, so the checkpoint search found nothing and
   `update_slots()` took the "forcing full prompt re-processing" path. Proven by instrumenting
   that branch: with an identical prompt and identical state, the only differing field between
   a working in-RAM hit and a failing post-restore request was `n_ckpt` (3 vs 0). Fixed by
   persisting the checkpoints alongside the snapshot: 10.01 s at 0% cached -> 0.17 s at 99.9%.
2. **The route actually adopted is not the slot API at all.** `--cache-disk-path` persists the
   in-RAM prompt cache and reloads it at startup, so nothing has to be saved or restored by
   hand. The slot API can only snapshot whatever request touched the slot last, and at `-np 1`
   Qwen Code interleaves small background requests with the big startup prompt, making that a
   lottery — see `llama-slot-save.sh` refusing at 9,109 tokens.

**Everything from here to the end of this section is the 2026-08-07 investigation, retained for
the reasoning trail. Its conclusion ("no") and its mechanism (the prefix matcher ignoring the
state) are both now known to be wrong.**

### The API, for reference

Three endpoints, all gated behind `--slot-save-path DIR`. Without that flag the server
replies *"This server does not support slots action. Start it with `--slot-save-path`"*.

```
POST /slots/{id}?action=save     {"filename":"x.bin"}  -> n_saved, n_written, timings.save_ms
POST /slots/{id}?action=restore  {"filename":"x.bin"}  -> n_restored, n_read, timings.restore_ms
POST /slots/{id}?action=erase                          -> n_erased
```

Everything is explicit: you name the slot in the URL and the file in the body, and you track
both yourself. Nothing is automatic. Measured on p14: save 16.8 ms, restore 4.5 ms for a
small slot; 101–126 ms and 72–112 ms respectively for a 34.8k-token one.

### What the file actually contains — the fixed 63 MiB floor

Not documented upstream, and worth knowing before designing anything around this. Saving a
**15-token** slot writes **66,028,248 bytes — 63 MiB**. Against a 34,825-token save at
445,596,488 bytes, the format decomposes cleanly:

```
per-token KV :  10,904 bytes   (10.65 KiB/token)
fixed floor  :  62.8 MiB       <- recurrent / SSM state
```

| tokens | file size |
|---|---|
| 15 | 63.0 MiB |
| 5,000 | 114.8 MiB |
| 34,825 | 425.0 MiB |
| 262,144 (full `-c`) | 2.7 GiB |

The floor is this model's hybrid architecture on disk. Of 41 blocks,
`qwen35moe.full_attention_interval = 4` means only ~10 carry a per-token KV cache; the other
31 are SSM layers whose state is **constant size regardless of context length**. So a
15-token conversation still costs 63 MiB. It also confirms the sizing derived from the GGUF
metadata independently: predicted 10.6 KiB/token, measured 10.65.

### What it was built for

Conversation switching on a busy multi-user server — park one conversation, load another,
swap back. **Not** restart persistence. That is why nothing is automatic, and why
[#17107](https://github.com/ggml-org/llama.cpp/issues/17107), asking for automatic KV
persistence to disk, was **closed as not planned**. The host-memory prompt cache
(`--cache-ram`) is documented as RAM-only by design.

The server README documents **no restrictions**, which is misleading — several are known:

| issue | restriction |
|---|---|
| [#21133](https://github.com/ggml-org/llama.cpp/issues/21133) | `--mmproj` sets `has_mtmd` on every slot, blocking save/restore even for text-only chats |
| [#19466](https://github.com/ggml-org/llama.cpp/issues/19466) | save broken on vision-enabled models |
| [#24746](https://github.com/ggml-org/llama.cpp/issues/24746) | explicit-slot requests skip the prompt-cache restore path entirely |
| [#18703](https://github.com/ggml-org/llama.cpp/issues/18703) | multi-model router does not support slot save/restore |

### The decisive test

Client-independent, so nothing about Qwen Code is in play. A fixed 9,913-token request sent
by `curl`:

| step | `cached_tokens` |
|---|---|
| send #1, cold | 0 |
| send #2, same server — **control** | **9,909 / 9,913** |
| save → restart → restore (`n_restored 9913`, 38 ms) → resend | **0** |
| same, with `cache_prompt: true` + `n_keep: -1` | **0** |

The control proves the prefix matcher works perfectly for this exact prompt. The restored
state is simply invisible to it.

Ruled out as causes, each tested directly:

- **`--mmproj` / #21133** — retested with the projector removed *and* a fresh snapshot
  captured on the projector-less server. No change.
- **`-np`** — tested at 1, 2 and 4, including `-np 1` to match the one third-party setup
  that reportedly works. No change.
- **`cache_prompt` / `n_keep`** — the remaining two knobs that setup injects. No change.
- **Qwen Code** — the probe above uses plain `curl`, so the client is not involved.

### What the cache already does

| | tokens | prefill |
|---|---|---|
| cold server, first Qwen Code launch | 34,804 | **97.2 s** @ 358–490 t/s |
| same server, second launch (new session) | ~34,800 | **none at all** — no `prompt processing` line |
| background fast/compaction request, second launch | 9,673 | 4 tokens processed |

So the in-RAM prompt cache is excellent and the opening prompt is genuinely stable across
sessions. The only hole is a restart, which empties it.

### Why the disk route fails

`--slot-save-path` was added to the unit and both halves of the API exercised:

```
POST /slots/0?action=save     -> {"n_saved": 34825, "n_written": 445596488, "save_ms": 126.4}
POST /slots/0?action=restore  -> {"n_restored": 34825, "restore_ms": 72.5}
```

Both succeed, and 425 MiB / 72 ms would have been a ~1300× win over a 97 s prefill. But the
next request still prefills all ~34.8k tokens, `n_prompt_tokens_cache = 0`.

The reason is visible in `GET /slots` immediately after a successful restore:

```json
{"id":0,"n_prompt_tokens":null,"n_prompt_tokens_cache":null,"n_prompt_tokens_processed":null}
```

**The KV bytes load, but the slot's prompt-token list is never populated.** The prefix
matcher and the `-sps` slot router both work off that list, so a restored slot is invisible
to them.

> **Corrected 2026-08-10 — this mechanism is wrong; see `disk-cache.md`.** A source read of
> build 458 shows the restore handler *does* populate the list
> (`server-context.cpp:2652`, `slot->prompt.tokens.insert(tokens)`), and the nulls above are
> an artefact of `server_slot::to_json` gating every one of those fields behind
> `if (ptask)` — on a freshly restarted server no task has run on the slot, so the keys are
> absent rather than zero. The cold prefill below is real; its cause is **unexplained**, not
> explained. Two confounds present in this unit were never varied: `-kvu` and
> `--spec-type draft-mtp`. Tested with `--cache-idle-slots` (default), with `--no-cache-idle-slots`, and with
a trivial "poke" request in between to force an idle-slot → prompt-cache migration. All
three prefilled cold.

### Theories chased and discarded

[#21133](https://github.com/ggml-org/llama.cpp/issues/21133) looked like an exact match:
loading a projector sets `slot.prompt.tokens.has_mtmd = true` on *every* slot at init, that
flag is read throughout the server as "this slot contains images" when it only means
"mmproj capability exists", and it gates `get_text_tokens()`, `insert()` and `set_token()`
behind `GGML_ASSERT(!has_mtmd)`. Same reported for save on vision models in
[#19466](https://github.com/ggml-org/llama.cpp/issues/19466). Compelling on paper, wrong
here — with `--mmproj` gone (`/props` showing `vision: false`) and a fresh snapshot taken
on that server, restore still produced a full 34.8k prefill at ~97 s. Projector is back in.

Worth recording so the next person does not re-run it: the failure looks identical whether
the cause is the projector, the slot count, or the request flags. Only the controlled probe
above distinguishes "restore is broken" from "your prompt did not match".

Related, and worth knowing before touching this again:

- [#22867](https://github.com/ggml-org/llama.cpp/issues/22867) — MTP + vision causes slot
  position corruption and OOM. This unit runs **both** `--spec-type draft-mtp` and
  `--mmproj`.
- [#22384](https://github.com/ggml-org/llama.cpp/issues/22384) /
  [#20225](https://github.com/ggml-org/llama.cpp/issues/20225) — for hybrid/recurrent
  models the checkpoint search tests `cur.pos_min < pos_min_thold`, but recurrent memory
  always reports `pos_min` = full sequence length, so it never matches; checkpoint creation
  also requires `n_tokens >= 64`. Fix proposed (`pos_max <= pos_next`), not merged upstream.
- **This bullet was the closest to right, and build 458 already carries the fix.** The
  `pos_max <= pos_next` workaround is present in the fork as
  `[TAG_CHECKPOINTS_FIX_POS_MIN]` in `server-context.cpp`, which is why the checkpoint search
  *does* match here — a live in-RAM hit was observed selecting the checkpoint at
  `pos_min = 5178` against `pos_min_thold = 5182`. The remaining gap was not the search but
  the fact that slot restore left the list it searches empty. Confirmed 2026-08-11: with
  `n_swa = 0` and `has_new_tokens = 0`, `pos_min_thold = pos_next - 1`, and recurrent
  `pos_min` equals that, so the guard fires on *every* request; the working and failing cases
  differed only in `n_ckpt`.
- ~~It is known to work elsewhere on this exact model: a third-party proxy measured 87 ms
  restore vs 9.9 s cold prefill, using `--parallel 1`, restoring immediately before each
  request, and injecting `"cache_prompt": true` / `"n_keep": -1`. Those are the three untried
  variables — `-np 1` in particular, since
  [#24746](https://github.com/ggml-org/llama.cpp/issues/24746) documents two divergent
  slot-selection paths, one of which never runs `prompt_save()` / `prompt_load()` /
  `prompt_cache->update()`.~~ **Disproven 2026-08-11.** All of it was tested: `-np 1`,
  restoring immediately before the request, and `cache_prompt`/`n_keep` all change nothing,
  and so do dropping `-kvu`, using f16 KV instead of q8_0, and disabling speculative decoding.
  Slot routing was never the problem — selection succeeded at `f_sim_best = 1.000,
  f_keep = 1.000`, which also means `update_cache` stayed false and neither `prompt_clear()`
  path ran.
- [qwen-code #5760](https://github.com/QwenLM/qwen-code/issues/5760) proposes exactly this
  upstream, naming Qwen3.6-35B-A3B and estimating 60–500 MiB state files. Ours is 425 MiB.
  Opened 2026-06-23, unassigned, no implementation.

`--slot-save-path` is left in the unit because it is inert unless the `/slots` API is
called, and it makes re-testing after a llama.cpp upgrade a one-command job. The
`ExecStartPost` restore hook is written but **deliberately not wired up** — it logs
`n_restored = 34825` and does nothing, which is worse than no hook at all.

### If this gets picked up again

The working alternative is a **warm-up**, not a restore: after `llama.service` starts, run
`qwen -i` once in the background, kill the client after its first response, and let the
~97 s prefill land in the RAM cache where it demonstrably *is* reusable. Two gotchas found
the hard way:

- **`qwen -p` is the wrong tool.** Headless mode uses a different core identity sentence
  ("a non-interactive CLI agent"), which diverges near the top of the system prompt and so
  shares almost no prefix with an interactive session. It must be `-i`.
- **Qwen Code clobbers slots on its own.** Within about a second of the first response it
  fires background `fastModel` / `compactionModel` requests, and with `-np 2` those
  overwrite the state you just warmed. Kill the client as soon as the first response lands.

`llama-slot-save.sh` and `llama-slot-restore.sh` are kept for the retry; the save half is
known good.

---

## The warm-up — built, measured, and removed

*Built 2026-08-07, removed the same day. Kept here as a record so it is not rebuilt.*

`llama-warmup.service` ran one throwaway `qwen -i` session after the server started, killed
it after the first response, and left the ~34.8k-token opening prompt sitting in the
`--cache-ram` prompt cache. It worked, and the numbers were good:

| | cold | after warm-up |
|---|---|---|
| first Qwen Code turn (34.8k context) | **~97 s** of prefill alone | **7–9 s**, near-zero prefill |

It cost ~101 s of background GPU per login, and re-ran automatically whenever
`llama.service` restarted.

### Why it was removed

It bought a one-off saving on the *first* turn of a session, and only in the directory it
warmed. Against that it ran a full inference workload at every login, needed a systemd unit
plus a 150-line script, and carried four separate non-obvious failure modes (below). The
in-session cache — which is where essentially all the benefit actually lives — needs none of
it: `--cache-ram 8192` already reuses a repeat prompt at ~100% with no help, measured at
`-np` 1, 2 and 4 alike.

So the machinery existed to optimise the one turn per session that the RAM cache does not
already cover, at the cost of being permanently installed infrastructure. Not worth it.

### What it cost to get right — the part worth remembering

Four things broke it, none of them obvious, and all four would bite again:

- **`qwen -p` is useless for warming.** Headless mode uses a different core identity
  sentence ("a non-interactive CLI agent"), which diverges near the top of the system
  prompt and shares almost no prefix with a real interactive session. It must be `qwen -i`,
  which needs a pty (`script -qec`) because it is a TUI.
- **`env: 'node': No such file or directory`.** `qwen` is a `#!/usr/bin/env node` script and
  nvm's node is not on `PATH` under systemd. The client died in under a second.
- **Polling `GET /slots` does not work.** A slot's `n_prompt_tokens` resets to 0 as soon as
  the next task arrives — about a second later, when Qwen Code's background `fastModel` /
  `compactionModel` requests fire. A 1 s poll misses the window and reports failure after a
  full 420 s despite having succeeded. The journal line
  `slot release: ... stop processing: n_tokens = 34832` is the reliable signal: it persists,
  reports the whole context length, and fires whether the prompt was prefilled or cached.
- **`PartOf=` needs `RemainAfterExit=yes`.** systemd only propagates restarts to units that
  are currently *active*, and a `oneshot` goes inactive the moment it exits — so without it
  the warm-up ran at login and never again.

And the finding that ultimately decided against it:

**A warm-up only helps in the directory it warmed.** Qwen Code's conversation-startup turn
carries the cwd and its folder structure, and changing directory costs the *entire* prefill,
not just that block:

| launch | tokens prefilled | time |
|---|---|---|
| same dir, **different** first message | 1,491 of 34,843 | 9 s |
| **different dir** | 34,676 of 34,702 | 101 s |

Reuse that only trims from the end is cheap; reuse that needs a rewind past a mid-prompt
divergence needs a context checkpoint, and checkpoint search is broken for hybrid/recurrent
models ([#22384](https://github.com/ggml-org/llama.cpp/issues/22384),
[#20225](https://github.com/ggml-org/llama.cpp/issues/20225)). A controlled `curl` test
confirms the asymmetry: appending a suffix to a cached prompt reused 6,582 of 7,627 tokens
(86%), a mid-prompt change reused nothing.

So covering real usage would have meant warming every directory you work in, at ~100 s each,
every login. `~/.qwen/usage_record.jsonl` showed 27 of 35 sessions from `$HOME` and the rest
scattered — the tail was never going to be worth it.

### If this is ever reconsidered

*Superseded 2026-08-08 — see below. The original text read: "The whole idea is only worth
revisiting if llama.cpp fixes partial prefix reuse for hybrid models, at which point a single
warm-up would cover every directory instead of one. Watch
[#22384](https://github.com/ggml-org/llama.cpp/issues/22384). Until then the RAM cache alone
is the right answer, and it needs no configuration."*

That conclusion assumed the warm-up had to come from **outside** the client, which is what
forced it to guess a directory. It missed a third option: **move the warm-up inside Qwen
Code**, which always knows the directory it was launched in. No llama.cpp fix required, and
[#22384](https://github.com/ggml-org/llama.cpp/issues/22384) stops being a blocker.

### The `max_tokens=1` warm request — measured 2026-08-08

Probe against the live server (`--cache-ram 8192`, `-np 4`), ~15k-token synthetic prefix with
a run-unique nonce so the run starts genuinely cold:

| step | request | prompt | cached | time |
|---|---|---|---|---|
| 1 | warm, `max_tokens=1`, cold prefix | 15,033 | 0 (0.0%) | **30.22 s** |
| 2 | real turn, same prefix, **different** user message | 15,041 | 15,021 (**99.9%**) | **0.94 s** |
| 3 | identical repeat (upper bound) | 15,041 | 15,037 (100.0%) | 0.73 s |
| 4 | unseen prefix (control) | 15,043 | 0 (0.0%) | 30.80 s |

**A one-token completion fully populates the prompt cache.** Step 2 is the finding: 30.22 s →
0.94 s, 32×, on a message the warm request never saw. Step 4 is the control that makes it
trustworthy — an unseen prefix still pays full freight, so step 2 is a real cache hit and not a
generally-warm server. Prefill measured ~497 t/s, in the same band as the 483 t/s figure
elsewhere in this file.

Two consequences:

- **Abort semantics do not matter.** An earlier design worried about firing a warm request and
  killing it mid-generation. Unnecessary — `max_tokens=1` completes normally and costs one
  token.
- **The warm request need not guess the user's first message.** Step 2 (99.9%) vs step 3
  (100.0%) differ by 16 tokens.

This does **not** survive a server restart — `--cache-ram` is still RAM-only, and
`llama.service` still restarts at every login. It removes the first-launch-per-directory cost,
not the first-launch-per-login one.

### Built and measured end-to-end — 2026-08-08

Implemented in a fork of Qwen Code (`~/code/qwen-code`, branch `warm-startup-prompt`, commit
`cd5dacb984`, not pushed): `GeminiClient.initialize()` fires the assembled startup prompt once
at `maxOutputTokens: 1`. Off by default behind `model.warmStartupPrompt`.

Measured with the real client and the real ~34.8k prompt — not the synthetic probe above. Each
run used a **fresh directory**, which is cold by construction, so no server restart was needed:

| condition | prefilled | total ctx | first turn |
|---|---|---|---|
| warm ON, **no user message typed** (isolates the warm) | 34,751 | — | ~98 s |
| **warmed dir**, real turn, separate process, warm OFF | **1,350** | 34,833 | **9 s** |
| **never-warmed dir** (negative control) | **34,809** | 34,826 | **100 s** |

**11× on the first turn**, and the control is what makes it trustworthy: a fresh directory still
paid 94.4 s of prefill at 368 t/s, so the 9 s is a genuine cache hit rather than an incidentally
warm server. The 1,350-token remainder matches the 1,491-of-34,843 baseline measured earlier in
this file for a same-directory launch with a different first message.

This also confirms the failure mode that mattered: tool declarations sit inside the cached
prefix, so a warm request that stripped them would diverge mid-prompt and reuse nothing — the
warmed run would have looked like the control. It did not.

**Measured 2026-08-10 — the risk was real, and it is a server flag, not a client fix.** The warm
is fire-and-forget, so typing immediately runs the real turn concurrently with it. At `-np 4`
both take separate slots and both prefill in full: on a 19.3k probe the real turn cost **81.8 s
at 0% cached**, against ~40.6 s for the same turn with no warm at all — a 2× penalty in both
latency and GPU. At **`-np 1`** the real turn queues behind the warm and inherits its cache:
**40.5 s at 99.9% cached**, i.e. exactly the cost of not warming, with 0.94 s if you wait for
the warm to land. Harness: `warm-tests/race-probe.py`; full table in item 6 of `TODO.md`.

Harness: `~/p14/warm-tests/` — `warm-step1.sh` (warm only), `warm-step2.sh` (real turn, warm
off), `cache-probe.py` (raw HTTP probe).

Plan and implementation seam: `~/.claude/plans/we-have-qwen-coder-groovy-gizmo.md`, and item 6
of `TODO.md`.

---

## Client ops — 2026-08-12

Four changes to the `~/code/qwen-code` side of the project. None of them are research; they are
the state of the install on this box, recorded so the next session does not have to re-derive it.

Two of them move the startup prompt, in opposite directions. Net for the day: **−731 tokens**
(computer use off, −1,363; Playwright MCP on, +632), or about 2 s of cold prefill at the
~357 tok/s ceiling.

### Synced the fork to upstream v0.21.10

`main` fast-forwarded 75 commits (`8c90697ace` → `4a281f2efc`, v0.21.9 → v0.21.10) and
`p14/prefill-progress` was rebased onto it. **The rebase was clean — no conflicts**, and the three
commits are byte-identical to their pre-sync versions.

Six files were touched by both sides: `core/client.ts`, `openaiContentGenerator/pipeline.ts`, both
`config.ts`, `settingsSchema.ts`, `core/index.ts`. A clean rebase is not proof the hooks still sit
in the right place, so the risky one was checked by hand: upstream's *"restore deferred MCP tools
on resumed sessions"* (#8475) edits `setTools()`, while the startup warm hangs off the end of
`initialize()` — different function, hook still correct.

| check | result |
|---|---|
| `npm run typecheck` | clean, all 10 workspaces |
| `npm run lint` | clean |
| `npm run build` + `npm run bundle` | succeeds, binary runs |
| prefill tests (core + CLI) | 16 + 37 pass |
| `client.test.ts`, `forkedAgent` | 322 pass |
| `openaiContentGenerator/` incl. `pipeline` | 824 pass |
| `config.test.ts`, `settingsSchema.test.ts` | 519 + 40 pass |

A fourth commit was added on top: **`test(core): mock getWarmStartupPrompt in the client test
config`**. The startup warm reads `config.getWarmStartupPrompt()` from `initialize()`, but the
shared mock config in `client.test.ts` never gained the getter, so every `initialize()` threw into
the warm's fire-and-forget catch — **330 unhandled errors across the suite, while all 322 tests
still passed**. The errors were pre-existing (they predate this sync; upstream just added more
tests, so the count grew). Worth knowing what the fix does *not* buy: mocking it to `false` stops
the noise but the warm still returns early, so `runForkedAgent`, `preserveTools: true` and
`maxOutputTokens: 1` remain uncovered by `client.test.ts`. The 330 errors were hiding that gap,
not filling it — see item 2 of TODO §6, still open.

**This sync used rebase, not the merge-while-testing convention**, and was force-pushed with
`--force-with-lease`. Consequence, stated because it is the exact thing that convention exists to
avoid: every SHA on the branch changed, so any build or measurement taken against the old commits
no longer refers to anything. Pre-sync state is recoverable from the local tag
`backup/pre-upstream-sync-20260812` in `~/code/qwen-code` until it is deleted.

### `qwen` on PATH now runs this repo

It previously resolved to a **stock npm install of v0.21.7 from 2026-08-06** — none of the prefill
work, none of the upstream update. It is now `npm link`ed: `qwen` → `~/code/qwen-code`, confirmed
by `qwen --version` reporting `0.21.10` from outside the repo.

Two consequences: the command **follows whatever branch is checked out** (switch to `main` and the
prefill feature is gone), and it **serves `dist/`, not `src/`** — source edits need
`npm run build && npm run bundle` before `qwen` sees them. Use `npm run dev` to run from
TypeScript directly. Restore the published build with `npm i -g @qwen-code/qwen-code`.

### Disabled computer use — worth 1,363 tokens of startup prompt

Set in `~/.qwen/settings.json`:

```json
"tools": { "computerUse": { "enabled": false } }
```

This is a hard gate, not cosmetic hiding. At `packages/core/src/config/config.ts:8447` the flag
wraps the entire registration, so with it false the module is never even dynamically imported:

```ts
if (this.isComputerUseEnabled()) {
  const { registerComputerUseTools } = await import('../tools/computer-use/index.js');
  await registerComputerUseTools(registerLazy, this);
}
```

**Why it belongs in this project's record rather than being a matter of taste:** the 35
`computer_use__*` tools are *deferred* built-ins, so their JSON schemas are correctly absent from
the function-declaration list — but every deferred tool is still advertised by name and
description in the startup reminder, via `getDeferredToolSummary()`, so the model knows what
`tool_search` can reach. That block is part of the ~41.6k prefix this whole project exists to
avoid paying for.

Measured, not estimated — the rendered block was reconstructed with the real truncation rule
(`MAX_DEFERRED_TOOL_DESC_LEN = 160`, first line only; 23 of the 35 descriptions get cut) and fed
to the running server's `/tokenize` endpoint, so this is the actual Qwen tokenizer:

| | |
|---|---|
| tools registered | 35 |
| rendered reminder block | 5,880 chars |
| **real tokens** | **1,363** (4.31 chars/token) |
| share of the ~41.6k startup prompt | ~3.3% |
| prefill time at the ~357 tok/s ceiling | **~3.8 s** |

So this is a small, permanent, free win on every cold prefill — the same class of win as the rest
of the project, and it costs nothing because the tools were never usable on this box anyway:

- **Ubuntu 26.04 is outside the vendor's verified matrix.** Cua verifies Debian 12, Ubuntu 22.04
  and 24.04, Rocky 9, Fedora 41.
- **This is a Wayland session** (`XDG_SESSION_TYPE=wayland`, GNOME). The native Wayland backend is
  preview-only behind `CUA_DRIVER_RS_ENABLE_WAYLAND=1`; X11/XWayland is the supported production
  path, and native-Wayland-only apps may be invisible to the driver entirely.
- **`toolkit-accessibility` is `false`** (the GNOME default). Without it the driver "loses the
  element tree that makes the backend useful" — it cannot read controls, so clicks and typing have
  nothing to aim at. `at-spi2-core` 2.60.4 *is* installed, and glibc 2.43 clears the 2.31 floor.

There is also one real upstream bug, [QwenLM/qwen-code#5922](https://github.com/QwenLM/qwen-code/issues/5922)
(closed): the driver is spawned as a persistent child on first use and burned ~7–8% CPU while
qwen-code sat idle. Triage put the cause in the daemon's own polling loop in `cua-driver-rs`, not
in qwen-code — so it is not Windows-specific despite being reported there. `computerUse.idleTimeoutMs`
(default 300000) reaps the process; disabling outright avoids it. On a battery-powered laptop
running a local model, an idle 8% CPU poll is not a rounding error. No Ubuntu- or Linux-specific
bug reports exist for this package.

The driver binary itself is still on disk at
`~/.qwen/computer-use/cua-driver-rs-0.5.2/cua-driver` (12 MB, fetched 2026-06-04). It is now inert
— nothing will launch it — but deleting it means re-downloading if this is ever re-enabled. The
pin is `CUA_DRIVER_VERSION = '0.5.2'` while the vendored contract package is 0.17.0, so the Linux
limitations above describe newer builds and may not all apply to 0.5.2.

Sources: [Inside Linux computer-use](https://cua.ai/blog/inside-linux-computer-use) (Cua),
[#5922](https://github.com/QwenLM/qwen-code/issues/5922).

### Added Playwright MCP + Chromium — costs 632 tokens, and it actually works here

The replacement for what computer use was supposed to do. Browser automation via
`@playwright/mcp`, driving its own bundled Chromium rather than the desktop.

```json
"mcpServers": { "playwright": { "command": "playwright-mcp", "args": [] } }
```

| | |
|---|---|
| package | `@playwright/mcp@0.0.79`, global npm install, binary `playwright-mcp` on PATH |
| browsers | `~/.cache/ms-playwright/` — `chromium-1234` (389 MB), `chromium_headless_shell-1234` (262 MB), `ffmpeg-1011` (4.9 MB); **656 MB total** |
| unrelated | `/usr/bin/google-chrome` is the system browser and is *not* what this drives by default |

> **Corrected 2026-08-14 — the browser claims in this section are wrong, and the config has since
> changed.** Three specific errors, found while setting up the Claude Code stack:
>
> 1. **`--browser` defaults to the `chrome` *channel*, not bundled Chromium.** So the last row
>    above is backwards: with `args: []` this drove **system Google Chrome**, confirmed from the
>    live process tree (`/opt/google/chrome/chrome --headless ...`). The 656 MB of downloaded
>    browsers was never touched.
> 2. **Those browsers could not have been used anyway.** `chromium-1234` is the wrong revision —
>    the `playwright-core` inside `@playwright/mcp@0.0.79` requires **1237**, and a direct launch
>    fails with `Executable doesn't exist`. The mismatch was latent because of error 1.
> 3. **The qwen config no longer matches line 862.** As observed 2026-08-14 it is
>    `--browser chrome --executable-path /usr/bin/chromium-browser` — snap Chromium
>    151.0.7922.108. Date of that change is unknown; it is not in git.
>
> The 1234 pair was **deleted** on 2026-08-14 and replaced with rev 1237 (Chrome for Testing
> 152.0.7977.8). **qwen-code is unaffected** — its explicit `--executable-path` bypasses the
> `ms-playwright` cache entirely.
>
> What *survives* unchanged is the reasoning below on why Playwright works where computer use did
> not: CDP instead of AT-SPI holds regardless of which browser is driven. Only the "browser it
> ships" clause is wrong. Full record in `browser-mcp.md`.

**Why this works where computer use did not:** Playwright drives a browser it ships and controls
over CDP. It never touches AT-SPI, never needs `toolkit-accessibility`, and does not care that this
is a Wayland session or that Ubuntu 26.04 is off the vendor's verified list — all three of the
blockers in the section above. The trade is scope: browsers only, not the desktop.

#### Prompt cost — measured the same way as computer use

MCP tools are deferred too (`shouldDefer: true`, `packages/core/src/tools/mcp-tool.ts:823`,
"discovered via ToolSearch to keep the initial tool-declaration list small"), so the same rule
applies: schemas stay out of the declaration list, but every tool is advertised by name and
truncated first-line description in the startup reminder, under a `#### playwright` heading.

Tool list pulled from the live server over stdio JSON-RPC, rendered with the real truncation rule,
tokenized against the running llama.cpp server:

| | computer use (removed) | playwright (added) |
|---|---|---|
| tools | 35 | **24** |
| descriptions truncated at 160 | 23 | **1** |
| rendered block | 5,880 chars | **2,494 chars** |
| **real tokens** | 1,363 | **632** |
| share of the ~41.6k prompt | ~3.3% | **~1.5%** |
| prefill at ~357 tok/s | ~3.8 s | **~1.8 s** |

**Less than half the prompt cost for a capability that is actually reachable on this hardware.**
Names are the long part — `mcp__playwright__browser_navigate_back` and friends — not the
descriptions, which is why only one of the 24 hits the 160-char cut.

#### Runtime cost

| | measured |
|---|---|
| MCP handshake | `initialize` ~370 ms, `tools/list` ~380 ms (n=3, tight spread) |
| idle server RSS | 109 MB |
| idle server CPU | **1.33%** steady state over 15 s (n=1) |
| browser at idle | **none** — launches lazily on first `browser_*` call |

The idle CPU is worth stating precisely, because the first number you get is wrong: `ps %cpu`
reports 21.6%, but that is a lifetime average dominated by startup. Sampled properly from
`/proc/<pid>/stat` over a 15 s window after settling, it is 1.33%. Real, but not the
7–8% persistent poll that got cua-driver removed — and the browser genuinely does not run until
asked, so there is no idle Chromium.

**The one to watch is memory, not CPU.** This box is at **54 GB used of 60, ~6 GB available** with
the model resident, and `image-gen.md` is already blocked on exactly that. `playwright-mcp`
defaults to **headed** — `--headless` is opt-in, and `args: []` takes the default — so the first
`browser_navigate` launches a full visible Chromium against that ~6 GB. Not yet measured under
load. If launches start failing or the model gets pushed out of GTT, add `--headless` (or
`--isolated` to keep the profile in RAM rather than on disk) as the first thing to try.

> **2026-08-14:** the `args: []` premise no longer holds — see the correction above; the browser
> launched is snap Chromium via `--executable-path`, still headed. The memory warning itself is
> unchanged and now larger: the Claude Code stack adds three more idle MCP servers totalling
> **343 MB** against the same ~6 GB. Chromium-under-load is still unmeasured. Note also that
> `--isolated` trades disk for **memory**, so it is the wrong lever if memory is what is short.

Also unmeasured: whether the ~370 ms handshake lands on the launch critical path. qwen-code
discovers MCP tools progressively — `client.ts` re-scans history in `setTools()` precisely because
"progressive MCP discovery registers tools after a resumed chat has already been constructed" — so
it plausibly overlaps the startup warm rather than delaying it. Worth confirming before treating
launch time as unchanged.

---

## Files here

| file | what it is |
|---|---|
| `llama.service` | the final working unit — **the deliverable** |
| `llama.service.as-found` | the unit as it was before this investigation, for diffing |
| `llama-test.service` | test unit for the `p14/disk-prompt-cache` fork — deliberately a byte-for-byte copy of `llama.service`'s flags plus the three `--cache-disk-*` flags and the fork binary, so any difference is the fork and not the configuration. `Conflicts=llama.service`: both bind `127.0.0.1:8080` and both want the whole GPU. Note `--cache-disk-min-tokens 20000` is a **reconstruction**, not a recorded value — see the comment in the unit |
| `bench-local.sh` | benchmark harness, same prompt shape as refhost's `bench-host.sh` |
| `bench-results.tsv` | every measurement taken on the **original mainboard**, all arms — history, not guidance |
| `bench-p16.sh` / `p16s-bench-results.tsv` / `p16s.md` | the 2026-08-21 P16s loan: a 2×2 of DPM × CPU governor that killed the governor theory. Still the best comparison point for this machine, because it ran the same server on the same DIMMs |
| `bench-dpm.sh` / `dpm-results.tsv` | **2026-08-22, the replacement mainboard.** DPM `auto` vs `high`, 4 interleaved rounds with GPU telemetry. The governor arm is dropped, so the same wall-clock buys more reps on the one live variable |
| `bench-prof.sh` / `prof-results.tsv` | **2026-08-22.** `platform_profile` A/B at fixed DPM, testing whether the replacement board is power-capped. Switches profile via `powerprofilesctl`, not a raw sysfs write — `power-profiles-daemon` owns that file and will fight you |
| `analyze.py` | summarises a telemetry TSV by arm, with and without round 1, plus a per-round drift table. Expects the `bench-p16.sh` column layout (with the `probe` column) |
| `root-helper.sh` | long-lived root helper so a whole benchmark needs one sudo dialog. **Read the trap comments at the top before reusing it** — two silent-hang failure modes, both hit on 2026-08-22 |
| `set-dpm-high.sh` | reapplies the DPM setting after a reboot. **Mostly obsolete on the replacement board** — see TODO item 2 |
| `llama-slot-save.sh` | snapshots a warm slot to disk — works (425 MiB, 126 ms), but **superseded**: at `-np 1` the slot rarely holds the startup prompt when you ask, so it refuses (`min 20000`) more often than it fires |
| `llama-slot-restore.sh` | restores one — was a no-op, **fixed 2026-08-11** by persisting `prompt.checkpoints`; still not wired up, and no longer needed since `--cache-disk-path` covers this without any script |
| `TODO.md` | open items |
| `disk-cache.md` | source read of the prompt-cache code, the L2 disk-tier design, and the 2026-08-11 root cause + implementation |
| `zed-sampling.md` | the 2026-08-14 Zed llama.cpp-provider work — per-profile sampling params, freezing the system prompt's date per thread (it was breaking the prompt cache once a day), the thinking toggle that did nothing on this provider, and `repetition_penalty` being silently dropped by llama-server. Builds on `disk-cache.md`; keeps the wrong turns, including three tests that lied |
| `browser-mcp.md` | the 2026-08-14 browser + JS-debug MCP stack for **Claude Code and Zed** — Playwright, chrome-devtools, mcp-debugger; the rev-1234/1237 mismatch this section got wrong; the global-install coupling across all three clients; and the measurement that matters most here — **Zed sends full tool schemas, so the same three servers cost 17,626 tokens, ~42% of the startup prompt**, against 632 for Playwright under qwen-code's deferred tools |
| `voice-asr.md` | local speech-to-text investigation — whisper.cpp + Qwen3-ASR, and why Qwen Code cannot yet use either |
| `image-gen.md` | local text-to-image — stable-diffusion.cpp + Z-Image-Turbo, built and staged but blocked on memory |

**Removed 2026-08-07:** `llama-warmup.sh` and `llama-warmup.service`. They worked (97 s → 7–9 s
on a session's first turn) but only in the directory they warmed, and the in-session RAM cache
covers everything else for free. See "The warm-up — built, measured, and removed".

Install the unit with:

```bash
cp ~/p14/llama.service ~/.config/systemd/user/llama.service
systemctl --user daemon-reload && systemctl --user restart llama.service
```

## Benchmark caveat

Measurements here are **n=2–4 per arm, not interleaved**. refhost's protocol is n≥10 across
two interleaved blocks. That is enough to resolve the large effects (DPM, wrapper) but
**not** a 2–3% difference — which is exactly why the 319-vs-458 comparison is reported as a
tie rather than a win for either. Re-run with the full protocol before citing any small
difference as real.
