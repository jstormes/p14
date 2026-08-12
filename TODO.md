# p14 — open items

## 2. DPM `high` is manual, and the GUI cannot reach it

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

---

## 6. ✅ Built and validated 2026-08-08 — warm the Qwen Code startup prompt

**Committed as `cd5dacb984` on branch `warm-startup-prompt` in `~/code/qwen-code`. Not pushed.
Off by default (`model.warmStartupPrompt`), so nothing has changed for normal use.**

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
3. **Run `npm run test:ci`** — only build/typecheck/pre-commit lint have run.
4. Untested paths: resumed sessions (they warm too), and headless `-p` (different system
   prompt per `README.md:501`).
5. **Then** log launch→first-message gaps over ~10 real launches. That number, not argument,
   decides whether the disk tier is worth building — see §5/§11 of the plan.

Test harness preserved in `~/p14/warm-tests/` (`warm-step1.sh` = warm only, `warm-step2.sh` =
real turn with warm off, `cache-probe.py` = the raw HTTP probe, `race-probe.py` = the warm-vs-
first-turn race, one run per `-np` setting).

**Also built 2026-08-10 — prefill progress in the UI** (branch `prefill-progress`, two commits
on top of `warm-startup-prompt`, not pushed). llama.cpp already streams
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
