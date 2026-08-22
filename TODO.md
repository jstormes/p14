# p14 — open items

> **2026-08-22 — the mainboard was replaced.** The original p14 board died; this is a new
> board, new power subsystem, newer BIOS, and the P16s' DIMMs. Item 2 is closed by that swap,
> items 8 and 9 are largely defused by the RAM going 60 → 88 GB, and items **10** and **11**
> are new. Item 11 is the one that wants action while the repair is recent. Background:
> `README.md` → "The 2026-08-22 re-measurement".
>
> | # | state |
> |---|---|
> | 2 | ✅ closed — DPM `high` is no longer a lever; stop running `set-dpm-high.sh` |
> | 3, 4, 5, 6, 7 | unchanged |
> | 8, 9 | memory worries largely defused by the RAM upgrade |
> | 10 | ⏳ new — `amdgpu.gttsize` still sized for the 60 GB box |
> | 11 | ✅ new, closed same day — the 23% was `amd_iommu=off` being removed on 08-21, not the board. Restored; +26% confirmed |
> | 12 | ✅ new, closed same day — BIOS VRAM carve-out does nothing; keep it minimum and take the 7 GB back |
> | 13 | ✅ new, closed same day — speculative decoding already optimal; `n-max` is a no-op, ngram types are worse |


## 2. ~~DPM `high` is manual, and the GUI cannot reach it~~ — closed 2026-08-22, stop doing this

> **The mainboard was replaced and this item is obsolete. Do not run `set-dpm-high.sh` as a
> matter of course.** On the replacement board, measured over 4 interleaved rounds
> (`dpm-results.tsv`):
>
> | arm | PP | TG | W | °C |
> |---|---|---|---|---|
> | `auto` (boot default) | 418.1 | **22.59** | **24.0** | **70.7** |
> | `high` | **473.1** | 20.65 | 53.1 | 94.7 |
>
> *(Current config, i.e. `amd_iommu=off` restored — `dpm-results-iommu-off.tsv`. The first
> version of this item quoted 350.2/374.9 from `dpm-results.tsv`, taken while the IOMMU was
> still on; see item 11.)*
>
> **+13.2% prefill, −8.6% generation, +121% power, +24 °C, and a 95 °C package.** For
> interactive coding that is a net loss: generation is what you sit and watch, and prefill is
> mostly cache hits. Run it only for a long batch prefill, and not otherwise.
>
> The "resets to `auto` on boot" fragility that this item existed to manage is therefore no
> longer a problem to solve — the boot default is now the setting you want. The decision
> below ("not persisted") stands, for a better reason than the one it was made for.
>
> See `README.md` → "The 2026-08-22 re-measurement" for why ~70% became ~7%: most likely the
> original ~1150 MHz / 13 W behaviour was a failing power subsystem, not a driver default.

*Original text, for the board that died:*

`power_dpm_force_performance_level` is a runtime sysfs write and resets to `auto` on boot,
taking ~70% of the recovered throughput with it. Reapply with `sudo ~/p14/set-dpm-high.sh`.

**Decided 2026-08-07: not persisted.** No udev rule, no hardcoded override — power belongs
to the desktop's own controls. The catch, measured rather than assumed:

| GNOME Power Mode | `platform_profile` | CPU governor | **GPU DPM** |
|---|---|---|---|
| Performance | performance | **performance** | **auto** |
| Balanced | balanced | powersave | **auto** |
| Power Saver | low-power | powersave | **auto** |

`power-profiles-daemon` drives the first two columns and **never touches the third**. So
switching to Performance in Settings gets the governor half of the win automatically, but
the DPM half — the larger one — stays off unless the script is run by hand.

That is the accepted trade: full speed is one `sudo ~/p14/set-dpm-high.sh` away when it
matters, and idle battery is untouched the rest of the time.

---

## 3. §7 of the refhost doc is **not** wrong — p14 just never met its precondition

*Rewritten 2026-08-07 after reading the doc properly. The earlier claim here was mistaken.*

§7 says to launch `vulkan/bin/llama-server` with `LD_LIBRARY_PATH=vulkan/bin`, bypassing the
toolbox wrapper and so using **system** Mesa. That is deliberate, and the doc says why:

> **Use system Mesa, not the toolbox's bundled driver.** The bundled Mesa 26.3.0-devel
> measured [slower than] the pinned 26.1.5.

The precondition is §11's `ppa:kisak/kisak-mesa` giving system Mesa
`26.1.5~kisak1~r`. **p14 never installed it** — system Mesa here is stock Ubuntu 26.0.3.
So on p14 the same command falls back to a driver a full minor version older than the one
§7 assumes, which is where the ~8% went. The instruction is right; the missing step is the
kisak PPA.

Two options, neither urgent: add the kisak PPA to match the doc, or keep the wrapper and
adopt 26.1.6 out-of-tree (item 4). The latter avoids a system-wide change.

---

## 4. ~~Adopt Mesa 26.1.6~~ — closed 2026-08-07, not worth anything

Retested properly (interleaved, under the doc's power state, first rep discarded): bundled
26.3.0 **483.2** vs kisak 26.1.6 **483.5**. A +0.4% difference — noise. The earlier ~3%
figure was measurement conditions, not the driver. **Nothing to adopt; the unit is already
on a driver as fast as any tested.** Only Mesa 26.0.3 is genuinely slow, and nothing uses it.

The extracted copy has been deleted (167 MB reclaimed). To recreate it, see the extraction
recipe in the Mesa section of `README.md` — .deb download plus `dpkg-deb -x` and an ICD
manifest, no PPA and no system-wide change.

---

## 5. ~~`performance` CPU governor~~ — closed 2026-08-07, the GUI already does it

The doc's §15 recipe includes a `performance` governor, which p14 never applied; the
2026-08-07 benchmark measured this configuration at **483** with it against **429**
without. No action needed: GNOME's **Power Mode → Performance** sets the governor to
`performance` via `power-profiles-daemon` (verified — see the table in item 2). Pick it in
Settings when throughput matters.

Caveat carried over to item 2: that same switch does **not** set GPU DPM, which is the
bigger half. And the benchmark moved DPM and governor together, so the ~10% is not cleanly
attributed to the governor alone.

> **Reopened and re-closed 2026-08-21 — the governor is worth ~0%, not ~10%.** A 2×2 of
> DPM × governor on the P16s (5 interleaved rounds, `p16s.md`) separates them for the first
> time: at fixed DPM, `performance` is **+1.7% at `auto` and −1.3% at `high`**, and at `high`
> it clocks the GPU *lower* (2816 vs 2899 MHz) and runs 6 °C hotter — a shared SoC power
> budget, so a busier CPU costs the GPU. The whole 429 → 483 was DPM plus rep-order.
> **Revised advice: leave the governor alone; Power Mode → Performance is not a throughput
> lever.** Not re-measured on p14 itself, but the mechanism is not chassis-specific.

---

## 6. ✅ Built and validated 2026-08-08 — warm the Qwen Code startup prompt

**Now four commits on branch `p14/prefill-progress` in `~/code/qwen-code`, pushed to
`origin/p14/prefill-progress`. Off by default (`model.warmStartupPrompt`), so nothing has changed
for normal use.**

> **SHAs below are stale.** This item was written against `cd5dacb984` on the since-deleted
> `warm-startup-prompt` branch. The work was rebased onto upstream v0.21.10 on 2026-08-12 and
> force-pushed, so every commit hash changed. The measurements still stand — the rebase was clean
> and the commits are byte-identical — but do not expect those hashes to resolve. See
> "Client ops — 2026-08-12" in `README.md`.

Measured end-to-end with the real client and the real ~34.8k prompt:

| condition | prefilled | total | first turn |
|---|---|---|---|
| warm ON, no user message | 34,751 | — | ~98 s |
| **warmed dir**, real turn, warm OFF | **1,350** | 34,833 | **9 s** |
| **never-warmed dir** (control) | **34,809** | 34,826 | **100 s** |

**11× on the first turn.** The control is the part that matters — a fresh directory still pays
94 s, so the 9 s is a real cache hit, not a warm server.

### → Pick up here

1. ✅ **Measured 2026-08-10 — the race is real, and `-np 1` fixes it entirely.**

   Reproduced with `warm-tests/race-probe.py`, which fires the two requests exactly as the
   client would — a `max_tokens=1` warm, then 250 ms later a real turn sharing its prefix but
   carrying a different user message. ~19.3k-token prefix, run-unique nonce so each arm starts
   cold. Power state as found (DPM `auto`, governor `powersave`), so treat the absolute
   seconds as a floor, not a benchmark.

   | | `-np 4` real turn | `-np 1` real turn |
   |---|---|---|
   | **you type immediately** | **81.84 s**, 0% cached | **40.49 s**, 99.9% cached |
   | **you read first** | 0.97 s, 99.9% cached | 0.94 s, 99.9% cached |
   | GPU wall, typing immediately | 82.10 s | **40.74 s** |

   **At `-np 4` the warm is a 2× penalty, not a wash.** Both requests took different slots and
   prefilled all 19,337 tokens with *zero* reuse, each at roughly half speed. A cold turn with
   no warm at all costs ~40.6 s — the warm's own solo time — so typing immediately with warming
   on costs 81.8 s against 40.6 s without it. It is a bet on your own typing speed, and losing
   it doubles both your wait and the GPU energy.

   **At `-np 1` the second request queues behind the warm and inherits its cache** — 99.9%
   reused even in the race arm. Worst case becomes exactly the cost of not warming; best case
   is 0.94 s. That turns the feature from a gamble into a strict improvement, and halves the
   GPU wall in the bad case.

   So the fix is not the client-side "await the in-flight warm" this item originally proposed.
   It is one flag on the server, and it needs no code at all.

   **The trade-off, stated honestly:** one slot means everything serialises. Qwen Code's
   background `fastModel` / `compactionModel` requests and any subagent forks now queue rather
   than run alongside — better for contention (the journal shows concurrent prefills at 217–241
   t/s against 339–351 t/s alone), worse if a long background request lands just before you
   press enter. Not measured; this box has one user, so the contention win is likely the larger
   effect.

   Side benefit worth remembering: `-np 1` is one of the three untried variables the README
   lists for the slot-restore no-op. Running it permanently makes that retest a one-command job
   — see `disk-cache.md`.
2. **Write a unit test pinning `preserveTools: true`.** It is the silent-failure trap: drop it
   and there is no error, just no speedup. Nothing currently guards it.
3. **Run `npm run test:ci`** — still not run. As of the 2026-08-12 upstream sync, typecheck, lint,
   build, bundle and the directly affected suites all pass (`client.test.ts`,
   `openaiContentGenerator/`, `config`, `settingsSchema`, both prefill test files — see
   `README.md`), but the full CI suite has never been run against this branch.
4. Untested paths: resumed sessions (they warm too), and headless `-p` (different system
   prompt per `README.md:501`).
5. **Then** log launch→first-message gaps over ~10 real launches. That number, not argument,
   decides whether the disk tier is worth building — see §5/§11 of the plan.

Test harness preserved in `~/p14/warm-tests/` (`warm-step1.sh` = warm only, `warm-step2.sh` =
real turn with warm off, `cache-probe.py` = the raw HTTP probe, `race-probe.py` = the warm-vs-
first-turn race, one run per `-np` setting).

**Also built 2026-08-10 — prefill progress in the UI** (the two commits on top of the warm, now
part of `p14/prefill-progress` and pushed). llama.cpp already streams
`prompt_progress {total, cache, processed, time_ms}` when a request sets `return_progress: true`;
nothing consumed it, because those chunks carry an empty delta and the content path discards
them. The client now renders them as a bar in place of the loading phrase, including during a
startup warm — when the session is otherwise `Idle` and the app looks inert while the GPU is
saturated. Enabled by `generationConfig.extra_body.return_progress` in
`~/.qwen/settings.json`; no request shape changes for anyone who does not ask for it.

**The version gotcha is gone as of 2026-08-10** — the fork was rebased onto upstream `8c90697ace`
(which carries `chore(release): v0.21.9`), so `--version` now distinguishes them:

| | reports |
|---|---|
| `qwen` (installed npm package) | **0.21.8** |
| `node ~/code/qwen-code/dist/cli.js` (the fork) | **0.21.9** |

Still invoke the fork by path — it is not linked into `PATH` — but a wrong-binary benchmark is now
detectable rather than silent. The version will collide again the moment npm ships 0.21.9, so check
rather than assume.

---

**Original scoping notes (2026-08-08).** Full plan:

```
~/.claude/plans/we-have-qwen-coder-groovy-gizmo.md
```

Was "UUID-keyed disk prompt cache across two forks". Now it is **one change to Qwen Code**:
after session init assembles the ~34.8k startup prompt, fire it once at `max_tokens=1` so the
prefill happens during launch instead of after the user's first message. **No llama.cpp fork,
no cache keys, no disk format.**

Why this works where `llama-warmup.service` failed: that service warmed only the directory it
ran in (`README.md:562`). Qwen warming *itself* at launch always warms the right directory.

Measured 2026-08-08 against the live server, ~15k synthetic prefix:

| step | prompt | cached | time |
|---|---|---|---|
| warm, `max_tokens=1`, cold | 15,033 | 0 (0.0%) | **30.22 s** |
| real turn, **different** message | 15,041 | 15,021 (**99.9%**) | **0.94 s** |
| unseen prefix (control) | 15,043 | 0 (0.0%) | 30.80 s |

Four things worth knowing before opening the plan:

- **A `max_tokens=1` request fully populates the cache**, and the following real turn reuses
  99.9% even with a different user message. Abort semantics are irrelevant — that whole
  question is dead.
- **`preserveTools: true` is mandatory and its absence fails silently.** Tools are inside the
  prefix; stripping them diverges mid-prompt, and mid-prompt divergence reuses *nothing* on
  Qwen3.6 hybrid. Wrong result looks like "no speedup", not like an error.
- **The build baseline is green** — `~/code/qwen-code`, branch `warm-startup-prompt` off
  `9e87453497`; `npm ci` / `build` / `typecheck` / `bundle` all exit 0. *(Superseded 2026-08-10:
  rebased onto upstream `8c90697ace`, re-verified green, and `--version` now tells the two
  binaries apart — see the version table above.)*
- **The disk tier is deferred, not cancelled**, and the probe demoted it: with warm-on-startup
  working, it saves background GPU rather than user-visible latency — a power optimization, not
  a latency fix. §5 of the plan; decide it by measuring how fast you actually start typing.

Prerequisite reading: the "Persisting the prompt cache across restarts" section of
`README.md`, which records what was already tried and disproved.

---

## 7. ✅ Built 2026-08-11 — the disk prompt cache, and the slot-restore bug behind it

`disk-cache.md` §"Implemented" has the detail. Summary, because it closes two open items above
and invalidates a conclusion in `README.md`:

**The slot-restore no-op is solved, and the recorded cause was wrong.** It was not the prefix
matcher ignoring the restored state and not the token list going unpopulated. `SLOT_RESTORE`
never repopulated `prompt.checkpoints`, and on this hybrid/recurrent model the server needs a
checkpoint to resume from on essentially every request (`llama_memory_seq_pos_min()` reports the
recurrent-state position, so `pos_min >= pos_min_thold` always holds). Empty list -> "forcing full
prompt re-processing". Instrumented proof: identical prompt, identical state, identical
`pos_min`/`pos_min_thold`, only `n_ckpt` differed (3 working vs 0 after restore).
**10.01 s at 0% cached -> 0.17 s at 99.9%.**

**Every flag previously suspected is cleared.** `-kvu`, `--spec-type draft-mtp`, quantized KV and
`-np` all reproduce the failure identically. Item 6's `-np 1` decision is unaffected and stands.

**The route adopted is `--cache-disk-path`, not the slot API.** Persists the in-RAM prompt cache
and reloads it at startup — no save script, no `ExecStartPost`, no slot lottery. Measured: 4
entries / 1994.5 MiB written in one session, all 4 reloaded at the next start in ~0.8 s, 0
discarded, leaving a ~41.6k-token prefix cached before the first request.

Code: **https://github.com/jstormes/llama.cpp** branch `p14/disk-prompt-cache`
(`52682e8d1`, `6f355f044` on `7a57bedaa` — still reports build 458). Worktree
`~/code/llama.cpp-458`.

### → Pick up here

1. **Explain the 3-vs-2 checkpoint discrepancy.** A save reported 3 checkpoints, the restore read
   back 2. Harmless in practice, but it must not ship in a PR.
2. **Verify the config fingerprint.** Compiled and wired but never exercised. Start once with
   `--cache-type-k f16` against a populated directory and confirm
   `discarding entry from a different configuration`.
3. **Measure divergent-prompt reuse.** The design assumes a prompt diverging at ~30k rewinds to
   the checkpoint at 24,576 and reuses that much. Unverified, and the value across day and
   directory changes depends entirely on it.
4. **Strip `__P14_DIAG__`** and split the commits before any upstream PR.
5. **Decide on fixed-boundary keying.** Entries are keyed on a hash of the whole token list, so a
   few-token change writes a new ~900 MiB file. `--cache-disk-max-entries 4` bounds it; hashing
   `tokens[0..K)` below the first volatile byte, or porting `alloc()`'s prefix-subsumption to
   disk, would collapse the variants into one.
6. **Two upstream contributions are available here**, independent of the disk tier: the
   checkpoint-persistence bug fix (slot save/restore loses `prompt.checkpoints`, so restored
   slots always full-reprocess on SWA/hybrid/recurrent models), and the `--cache-disk-path` tier
   itself. The first is a small, clearly-correct fix worth filing regardless.

### The judgement from `disk-cache.md` §"Honest scope note" still holds

Warm-on-startup already collected the latency win. What this adds is surviving the
`llama.service` restart that happens at every login, for **any** client rather than only the
forked Qwen Code. It does not make a first turn faster on a launch where the warm had time to run.

---

## 8. ⏳ Open 2026-08-12 — Playwright MCP is in, two things unmeasured

Setup and the prompt-cost measurement are in `README.md` → "Client ops — 2026-08-12". It costs
**632 tokens** of startup prompt against computer use's 1,363, and it works on this box where
computer use could not. Two loose ends, both cheap to close:

1. **Headed Chromium against ~6 GB free.**

   > **Largely defused 2026-08-22 by the RAM upgrade.** This was written when the box had
   > 60 GB and sat at 54/60 with the model resident. It now has **88 GB**, and with the model
   > up it sits at ~46 GB used with **~37 GB available**. A headed Chromium no longer competes
   > for the last 6 GB of anything. The GTT side is unchanged and is now the tighter
   > constraint (35.8 of 49.1 GiB used — see item 10), but Chromium does not live in GTT.
   > **Downgraded from "measure before assuming" to "just use it."**

   `playwright-mcp` is **headed by default** and
   `args: []` takes that default, so the first `browser_navigate` launches a full visible
   Chromium on a box sitting at 54/60 GB with the model resident — the same wall that blocked
   `image-gen.md`. Not yet tried under load. If it fails or pushes the model out of GTT, add
   `--headless` first, then `--isolated` (profile in RAM, not on disk). Measure RSS during an
   actual browse before assuming either is needed.

2. **Does the ~370 ms MCP handshake sit on the launch critical path?** qwen-code discovers MCP
   tools progressively (`client.ts` re-scans history in `setTools()` because "progressive MCP
   discovery registers tools after a resumed chat has already been constructed"), so it may well
   overlap the startup warm rather than delay it. Until that is confirmed, do not claim launch
   time is unchanged — and note it interacts with §6: the warm and the MCP handshake fire at
   roughly the same moment.

Both are launch-time/memory questions, not correctness ones. Nothing is broken today.

---

## 9. ⏳ Open 2026-08-16 — the Agent Debug Browser is built, but never driven by an agent

All three clients (qwen-code, Claude Code, Zed) now attach over CDP to one visible Chrome for
Testing on `:9222`, started from a desktop icon. Setup, both traps and the sandbox verification are
in `browser-mcp.md` → "Shared visible browser". The capability eval that motivated it is
`browser-eval.md`.

Working and verified: both MCP servers attach to the same instance, the bare-ref rule holds over
CDP, and the sandbox is genuinely on (`chrome-for-testing` label, renderer in a different user
namespace from the browser).

Loose ends, in the order they are likely to bite:

1. **No agent turn has been run against it.** Every check was made with a direct MCP client, not
   through an actual client driving a task. This is the same gap the Zed section had, reopened one
   layer up. Cheapest close: one real qwen-code turn that navigates and clicks something.

2. **Memory under load — now the sharpest version of §8's loose end #1.** *(Also defused
   2026-08-22: 88 GB installed, ~37 GB available with the model resident. Still the oldest
   unmeasured thing in the project, but no longer the risk it was written as.)* That item worried about a
   headed Chromium against ~6 GB free. This makes it *worse on purpose*: the browser is headed, has
   a persistent on-disk profile rather than `--isolated`, and stays resident between agent turns
   instead of being torn down. It replaces three potential `--isolated` headless browsers with one
   long-lived headed one, so the direction of the change is not obvious — measure RSS during a real
   browse before assuming either way. **Still the oldest unmeasured thing in this project.**

3. **Concurrent agents sharing one browser is untested.** `-np 1` on llama-server serialises the
   model, so two agents interleaving tabs has not come up. Nothing prevents it, and nothing
   allocates tabs between clients.

4. **The port is hard-coded in three client configs.** `AGENT_BROWSER_PORT` moves the browser but
   not the clients. Fine until it isn't; a shared source would mean generating the configs.

5. **GNOME rendering the desktop icon was never observed.** It validates and is marked trusted.

Not planned: auto-start via a systemd user service. It would need `graphical-session.target`
binding like `llama.service`, and a debug browser that appears without being asked for is its own
annoyance. Revisit if "browser wasn't running" becomes a recurring failure.

---

## 10. ⏳ Open 2026-08-22 — `amdgpu.gttsize` is still sized for the 60 GB box

> **Note added after the carve-out test.** Raising `gttsize` buys **capacity, not speed** —
> `dpm-results-uma1g.tsv` shows that moving ~7 GiB of the model between VRAM and GTT changes
> nothing measurable, so where the weights sit is not a performance question on this hardware.
> Raise it only when you actually need a bigger context, a bigger model, or two resident.
>
> The 2026-08-22 carve-out change makes this *less* tight: RAM went 83 → 90 GiB usable, so
> there is now more headroom to raise `gttsize` into if you want it.

The kernel command line carries:

```
amdgpu.gttsize=49152 ttm.pages_limit=12582912 ttm.page_pool_size=12582912
```

49152 MiB of GTT, and `12582912` pages × 4 KiB = the same 48 GiB. That was an aggressive
number when the machine had 60 GB of usable RAM — it claimed 80% of it. On 88 GB it is
merely 55%, and it is now **the binding limit rather than RAM**:

| | |
|---|---|
| GTT used, model resident at `-c 262144` | **35769 MiB** |
| GTT total | 49152 MiB |
| headroom | ~13 GiB |
| RAM still free for everything else | ~37 GiB available |

So there is ~30 GB of RAM that the GPU is structurally unable to reach. Raising both values
together is the lever for a larger context, a larger model, or a second resident model — but
**neither has been tested at a higher value on this board**, and both are boot-time, so a bad
value costs a reboot. Raise `gttsize` and `ttm.pages_limit` in step; setting only one has no
effect.

Related: this is what makes item 8's and item 9's memory worries much less sharp than when
they were written — see the note added to both.

---

## 11. ✅ Closed 2026-08-22 — it was `amd_iommu=off`, and the mainboard is fine

`amd_iommu=off` was removed from `/etc/default/grub` at 13:13 on 2026-08-21 to unblock the NPU
(`npu-after-reboot.sh`: XDNA2 needs SVA, SVA needs the IOMMU). Restored 2026-08-22 and
rebooted. Same board, same DIMMs, same server, same harness, same power state — only the boot
flag differs. Steady state, round 1 dropped, n=3 (`dpm-results-iommu-off.tsv`):

| arm | metric | IOMMU on | IOMMU off | gain | P16s | vs P16s |
|---|---|---|---|---|---|---|
| `auto` | PP | 350.2 | **418.1** | **+19.4%** | 429.7 | −2.7% |
| | TG | 19.67 | **22.59** | **+14.9%** | 22.67 | −0.3% |
| | sclk | 2169 MHz | 1922 MHz | −11.4% | 1971 MHz | −2.5% |
| `high` | PP | 374.9 | **473.1** | **+26.2%** | 487.7 | −3.0% |
| | TG | 17.81 | **20.65** | **+16.0%** | 21.68 | −4.7% |
| | W | 46.7 | **53.1** | **+13.7%** | 54.8 | −3.1% |

**The board is within 3% of the P16s on both arms.** No hardware deficit. The model is
GTT-resident, so the IOMMU put address translation on every GPU access to 36 GiB of system RAM;
removing it restores both the throughput and the power draw (53.1 W at 2900 MHz, against the
P16s' 54.8 W — the "low power" was stalling, not a cap).

**Nothing further to do.** The NPU path the flag was removed for is abandoned as not
competitive, so the revert costs nothing. Previous GRUB saved at
`/etc/default/grub.bak-claude-20260822`.

### What this item is worth keeping for

Three readings were published and retracted before the cause was found. In order:

1. *"Thermally limited — probably heatsink seating from the repair."* Killed by the DPM `auto`
   row: identical power, higher clock, cooler, still slower.
2. *"The replacement board is 23% slower at the top end."* Confounded — a P16s measured with
   `amd_iommu=off` against a p14 measured with the IOMMU on. **This was heading toward a
   warranty claim against a healthy board.**
3. *"The P16s showed the same signature under lemonade contention."* Right observation, wrong
   mechanism: `lemonade-deb-interleaved.tsv` was written at 14:03 on 2026-08-21, *after* the
   13:16 reboot, so those runs had the IOMMU on too. A fourth data point for the flag.

The signature reading — "this is a memory stall" — was correct every time. What was wrong was
attributing it to hardware without checking the software configuration hadn't moved underneath
the comparison.

**The rule:** when throughput on this box looks ~20% low, **check `/proc/cmdline` before
suspecting hardware.** README's "Ruled out" table asserted `amd_iommu=off` was "already set";
it had been false for a day, and nothing in DMI, the hostname, or the benchmark output said so.

**Harness gap, still open:** `bench-dpm.sh` and `bench-prof.sh` sample `sclk` only. Add
`mclk`/`fclk`/`socclk` — and have the harness record `/proc/cmdline` into the TSV header, which
would have caught this on the first run.

---

## 12. ✅ Closed 2026-08-22 — BIOS VRAM carve-out: tested, and it does nothing

**Do not retest this.** The hypothesis was that the carve-out mattered: with 8 GB, VRAM ran
100% full (8157/8192 MiB) and ~36 GiB of the model spilled into GTT. VRAM goes through the
local aperture, GTT through the GART — and having just measured that a translation layer on GTT
cost 26% (item 11), moving *more* of the model into VRAM looked like the obvious next win.

Tested in the opposite direction — carve-out cut **8 GB → 1 GB**, so ~7 GiB *more* of the model
went to GTT. Matched protocol, `amd_iommu=off` on both, `dpm-results-uma1g.tsv`:

| arm | metric | UMA 8 GB | UMA 1 GB | delta |
|---|---|---|---|---|
| `auto` | PP | 418.1 | 420.3 | +0.5% |
| `auto` | TG | 22.59 | 22.70 | +0.5% |
| `high` | PP | 473.1 | 480.4 | +1.5% |
| `high` | TG | 20.65 | 21.09 | +2.1% |
| `high` | °C | 94.7 | 89.7 | −5.3% |

**All PP/TG deltas are inside the run-to-run spread (sd ~5 on PP).** VRAM-vs-GTT placement is
not a lever here. With `amd_iommu=off` the remaining GART translation runs on the GPU's own page
tables with large fragments, and both pools are the same physical DDR5 at the same bandwidth —
the IOMMU was an extra layer on top, and the GART itself is cheap.

*(The −5 °C is the only figure outside obvious noise and is **not** attributed: thermal history
across two separate boots is a likelier cause than the carve-out.)*

**Keep the carve-out at minimum.** Same throughput, **7 GB back to the OS** (83 → 90 GiB).

### Where to look instead

`quant-q8-vs-q4kxl.tsv`, steady state: Q4_K_XL vs Q8_0 is **a wash on prefill** (253–254 vs
257–259) and **+15% on generation** (19.6–21.0 vs 17.3–17.7). Halving the model's bytes did
nothing for PP. So on this box **prefill is compute-bound, generation is bandwidth-bound** —
memory-side tuning moves TG, not PP.

Untested, cheapest first:

1. **`-ub` / `-b` batch geometry.** Currently `-ub 1024 -b 8192`. Since prefill is
   compute-bound this is the live prefill knob. One flag, one restart, no reboot.
2. **KV cache `f16` vs `q8_0`.** Currently `q8_0` for both at 256k context, and there is GTT
   headroom now. Trades dequant work against bandwidth; could go either way.
3. **Q4_K_XL as the served model** — already +15% TG for no PP cost, but measured with the
   IOMMU on; worth re-measuring. Quality call.
4. **THP** — `madvise` today, `AnonHugePages: 0`. Free to test, but the weights live in device
   memory, so it probably cannot help.
5. **`amdgpu.vm_fragment_size`** — `-1` (auto) already picks the largest supported fragment.
   Low value, costs a reboot. Last resort.

---

## 13. ✅ Closed 2026-08-22 — speculative decoding: current config is already optimal

Two questions, both answered, **neither requiring a change**.

**1. `--spec-draft-n-max` is a no-op with `draft-mtp`. Do not touch it.**

The unit sets `2`; the build defaults to `3`; acceptance runs at ~76%. That looked like an
obvious free win. It isn't — measured per-request with `speculative.n_max` at 1, 2 and 6, draft
tokens per output token were **0.74 / 0.77 / 0.77**. Qwen3.6's MTP head emits **one** draft
token per step regardless, so the cap is not the binding constraint.

**2. `draft-mtp` is the best of the four available types, worth +13% TG.**

`bench-spec.sh`, 3 rounds, 18k cold prompt, 400 generated tokens, one server per arm
(`spec-results.tsv`):

| arm | TG | sd | vs `none` | draft/tok | accept% | PP |
|---|---|---|---|---|---|---|
| `none` | 18.86 | 0.06 | — | 0.00 | 0.0 | 449.8 |
| **`draft-mtp`** *(configured)* | **21.32** | 0.78 | **+13.0%** | 1.00 | **65.9** | 431.2 |
| `ngram-cache` | 12.78 | 3.40 | **−32.3%** | 0.59 | 12.7 | 445.8 |
| `ngram-map-k` | 18.26 | 0.40 | −3.2% | 0.16 | 7.6 | 433.2 |

**Nothing to change.** The ngram variants are recorded so nobody retries them: their drafts are
rejected 87–92% of the time, and `ngram-cache` is **worse than no speculation at all** — rejected
drafts cost verify work for nothing. `draft-eagle3`, `draft-dflash` and `draft-dspark` were not
tested; they need a separate draft model, which this box does not have.

**The trade, honestly:** `draft-mtp` costs ~4% of *prefill* to buy +13% of *generation*. Net
positive for interactive use, where prefill is mostly cache hits and generation is what you
watch.

⚠ **Method caveat:** arms ran in fixed order within each round rather than randomised, so
position and thermal effects are not fully separated from arm effects. The TG gaps are far too
large for that to matter; the ~4% PP figure is the one to re-measure with randomised order
before citing it as exact.

### What is left on the TG side

Speculation is now closed. The remaining bandwidth-side levers are item 12's list —
**Q4_K_XL (+15% TG measured, PP a wash)** is the largest, and it is a quality call rather than a
tuning one. KV `f16` vs `q8_0` is the next cheap test.
