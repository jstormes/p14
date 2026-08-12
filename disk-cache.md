# A disk-backed prompt cache for llama.cpp — source read and design

*Started 2026-08-10. Supersedes the "Phase 0" gate in §5 of
`~/.claude/plans/we-have-qwen-coder-groovy-gizmo.md`, which asked for exactly this source read
before the disk tier could be scoped.*

**Read first:** "Persisting the prompt cache across restarts" in `README.md` (what was tried and
disproved), and item 6 of `TODO.md` (the warm-on-startup work that made this a power
optimization rather than a latency fix).

---

## Where the startup time actually goes — measured 2026-08-10

Before any of the design below is worth building, this is what a cold launch costs, read out of
`journalctl --user -u llama.service` rather than estimated:

| component | measured | notes |
|---|---|---|
| model load | **13.7–15.3 s** | 5 samples, consistent. Paid once per `llama.service` start, i.e. per login. |
| startup-prompt prefill | **118.5 / 122.6 / 137.7 s** | 41,553–41,592 tokens at 302–351 t/s |
| — the same prefill on 2026-08-08 | 94.4 s | 34,809 tokens at 368.8 t/s |
| client-side (node start, tool registry warm) | **unmeasured** | the ~30–45 s left over from a ~180 s wall-clock launch |

Two things fall out of this that were not visible when `README.md` was written.

**The startup prompt grew 19% — 34,809 → 41,592 tokens — between 2026-08-08 and 2026-08-09.**
There are no MCP servers configured and no `QWEN.md`, so this is core tool schemas and the skills
snapshot. Prefill is linear in prompt length, so that growth alone costs ~23 s per cold launch,
and it will keep drifting upward with the client.

**Throughput is 302–351 t/s, against the 483–490 t/s this box benchmarks at.** The machine is
sitting at `power_dpm_force_performance_level = auto`, governor `powersave`, GNOME Balanced — the
configuration `TODO.md` items 2 and 5 measure as costing ~70% and ~10% respectively. Some of the
gap is depth (the rate decays 508 t/s at 8k to 340 t/s at 41.6k as attention grows), but not all
of it. **No benchmark in this folder should be run, and no optimisation judged, without
`sudo ~/p14/set-dpm-high.sh` applied first.**

### Concurrency was expensive — resolved 2026-08-10 by `-np 1`

The journal shows what happens when two prefills overlap — tasks 268 and 269 running together
drop to **217 and 241 t/s**, against 339–351 t/s for a prefill that has the GPU to itself. That
was the missing measurement from item 6.1 of `TODO.md`, from the other direction: the race
between a fire-and-forget warm and a user who types immediately was not merely "two prefills",
it was two prefills each running ~35% slower than one.

Directly measured since, with `warm-tests/race-probe.py`: at `-np 4` the racing real turn cost
**81.8 s at 0% cached**, against ~40.6 s for the same turn with no warm at all. At `-np 1` it
queues behind the warm and inherits its cache — **40.5 s at 99.9% cached**.

**`-np 1` is now the production setting** (`llama.service`, 2026-08-10). Concurrency is no
longer a variable in anything measured here, and the warm is safe to enable. Full table in item
6 of `TODO.md`.

---

## What is being built, and where

Not a fix to `/slots?action=save|restore`. **An L2 disk tier underneath the existing
`--cache-ram` prompt cache**, which is a different and much better-behaved piece of code.

The distinction matters because it decides whether the p14 no-op is a blocker. It is not: the
disk tier never touches the slot save/restore path, and it reuses the one function that already
does the bookkeeping correctly.

---

## Phase 0 — the source read, and a correction

Line numbers are for fork commit `7a57bedaaed7` (2026-08-05), which is the build the running
`llama.service` reports as `version: 458 (7a57bed)`. `server-task.cpp`, `server-task.h`,
`server-common.cpp` and `server-common.h` are **byte-identical** to upstream master as of today,
and the 36-line drift in `server-context.cpp` is entirely speculative-decoding and
backend-sampling work — none of it touches caching. So this reading holds for both trees.

### The README's stated mechanism is wrong

`README.md` concludes:

> **The KV bytes load, but the slot's prompt-token list is never populated.**

The handler does populate it. `tools/server/server-context.cpp:2621` (`SERVER_TASK_TYPE_SLOT_RESTORE`):

```cpp
size_t nread = llama_state_seq_load_file(ctx_tgt, filepath.c_str(), slot->id, tokens.data(), tokens.size(), &token_count);
if (nread == 0) { ... }
tokens.resize(token_count);
slot->prompt.clear();
slot->prompt.tokens.insert(tokens);     // <- server-context.cpp:2652
```

### The observation that led there has a benign explanation

The evidence was `GET /slots` returning nulls immediately after a successful restore. That is
`server_slot::to_json` at `server-context.cpp:679`:

```cpp
const auto & ptask = task ? task : task_prev;        // :689
if (ptask) {
    res["n_prompt_tokens"] = (int32_t) prompt.tokens.size();   // :693
    ...
}
```

Every one of those fields lives inside `if (ptask)`. On a freshly restarted server no task has
ever run on the slot, so `task` and `task_prev` are both null and the keys are simply **absent**
— which reads back as `null`. It reports "no task has run here yet", not "the token list is
empty". The restored token list is invisible to `/slots` by construction.

**So the failure is unexplained, not explained.** That is a demotion, not a fix: restore still
demonstrably produced a cold prefill in the controlled `curl` probe. But the mechanism recorded
in `README.md` should not be relied on, and the two confounds the source now implicates were
never tested — see "The cheap experiment" below.

### What slot-selection actually does with a restored slot

Worth recording because it removes another candidate. `get_available_slot`
(`server-context.cpp:1590`) has three tiers: explicit `id_slot`, then LCP similarity, then LRU.
The LCP tier is gated on `slot_prompt_similarity != 0.0f`, and `-sps` **defaults to 0.10**, so it
is live. A restored slot 0 holding 34,825 matching tokens scores `f_sim ≈ 1.0` and wins. Slot
routing is not the problem.

---

## The seam — `server_prompt_cache`

This is the class behind `--cache-ram`, and it is small. `tools/server/server-task.h:592-660`:

```cpp
struct server_prompt        { server_tokens tokens; std::list<common_prompt_checkpoint> checkpoints; };
struct server_prompt_data   { std::vector<uint8_t> main; std::vector<uint8_t> drft; };
struct server_prompt_cache_state { server_prompt prompt; server_prompt_data data; };

struct server_prompt_cache {
    std::list<server_prompt_cache_state> states;   // <- the entire cache, in RAM
    size_t limit_size, limit_tokens;
    server_prompt_cache_state * alloc(...);        // server-task.cpp:1664
    bool  load (...);                              // server-task.cpp:1746
    void  update();                                // server-task.cpp:1823
};
```

An entry is **fully self-describing**: a token vector, the checkpoints, and the two opaque state
blobs produced by `llama_state_seq_get_data_ext`. Nothing else. Serializing that to a file is
mechanical.

**The load path is the reason to build here.** `server_prompt_cache::load`
(`server-task.cpp:1746`) picks the best entry by `f_keep` / `f_sim`, pushes the bytes back with
`llama_state_seq_set_data_ext`, and then does:

```cpp
prompt = std::move(it_best->prompt);      // server-task.cpp:1812
```

It restores the KV **and** hands the slot its token list, in one place, in code that is exercised
on every request today. A disk tier that feeds this function inherits correct bookkeeping for
free — which is precisely the thing the slot-restore path is suspected of getting wrong.

### Where the bytes get filled — a trap

`alloc()` only *sizes* the buffers. `server_slot::prompt_save` (`server-context.cpp:256`) fills
them afterwards:

```cpp
auto * cur = prompt_cache.alloc(prompt, cur_size_tgt, cur_size_dft);
if (cur == nullptr) return false;
llama_state_seq_get_data_ext(ctx_tgt, cur->data.main.data(), cur_size_tgt, id, ...);
if (ctx_dft) llama_state_seq_get_data_ext(ctx_dft, cur->data.drft.data(), cur_size_dft, id, ...);
```

**Write to disk here, not in `alloc()`** — at `alloc()` time the buffers are allocated and empty.
An implementation that hooks `alloc()` will silently persist 425 MiB of zeros.

### And a second one — the RAM cache is move-out

`load()` ends with `data.clear(); data.shrink_to_fit();` and `states.erase(it_best)`. A RAM hit
**consumes** the entry. If the disk copy were written only on eviction it would never exist for
the entries that matter. Write-through at save time is the only correct policy.

---

## Design

### Flags

| flag | meaning |
|---|---|
| `--cache-disk-path DIR` | enable the L2 tier, entries stored here. Absent = today's behaviour, byte for byte. |
| `--cache-disk N` | byte budget in MiB, LRU by mtime. Default something like 16384. |

Keys are **server-computed**, per §5 of the plan: no caller-supplied filename, therefore no
path-traversal surface, and prefix drift (edit `QWEN.md`, upgrade the client, add an MCP server)
turns into a clean miss instead of a 425 MiB read followed by a full reprefill.

### Three hooks

1. **Write-through**, in `prompt_save` immediately after the two
   `llama_state_seq_get_data_ext` calls (`server-context.cpp:272-276`). Serialize the entry,
   `write` + `rename` for atomicity so a crash mid-write cannot leave a torn file.
2. **Read on miss**, at the end of `server_prompt_cache::load` (`server-task.cpp:1746`) when the
   in-RAM scan yields `it_best == states.end()`. Score the disk index by the same `f_keep` /
   `f_sim` rules, read the winner into a temporary `server_prompt_cache_state`, then fall into
   the *existing* restore block. Do not write a second restore path.
3. **Index at startup**, in the `server_prompt_cache` constructor. Read **headers only** —
   tokens and payload lengths, not the 425 MiB blobs. The payload is read only on a hit.

### File format

Versioned and self-validating, because a stale blob against a changed model is a crash risk:

```
"LCPD" | u32 version
u64 cfg_hash                 // see below
u32 n_tokens | llama_token[n_tokens]
u32 n_checkpoints | { pos_min, pos_max, u64 len, u8[len] } *
u64 len_main | u8[len_main]
u64 len_drft | u8[len_drft]
```

`cfg_hash` must cover **everything that changes the state layout**: the model file identity
(path + size + mtime, or the GGUF hash), `-c`, `-ctk`/`-ctv`, `-np`, `-kvu`, and the draft-model
configuration (`--spec-type`, `--spec-draft-type-k/v`). Mismatch is a miss, and the file is
unlinked. Belt and braces: `llama_state_seq_set_data_ext` returns a byte count — treat any value
`!= size` as a miss and delete, exactly as the RAM path already does at `server-task.cpp:1789`.

### `--mmproj` is not a blocker here

It blocks the *slot* save path (`check_slot_no_media`, and issue #21133), but this tier does not
go through it. `server_tokens` already exposes what is needed, both public and neither of them
asserting on `has_mtmd`:

- `has_media()` (`server-common.h:217`) — true only if the conversation **actually contains**
  image/audio chunks, as opposed to `has_mtmd`, which only means a projector is loaded.
- `get_text_tokens()` (`server-common.cpp:411`) — no assert, unlike `get_tokens()` at
  `server-common.cpp:406` which does `GGML_ASSERT(!has_mtmd)`.

For a text-only conversation the media map is empty, so `get_text_tokens()` round-trips the
vector exactly and `pos_next()` (`server-common.cpp:247`) returns `tokens.size()` unchanged.
**Refuse to persist any entry where `has_media()` is true** and the whole mtmd problem is gone.

### Sizing

From the measurements already in `README.md`: 62.8 MiB fixed floor (the SSM/recurrent state of
this hybrid model) plus 10.65 KiB/token — **~425 MiB** for a whole Qwen Code startup prompt, or
~399 MiB for a snapshot taken at a 32,768-token boundary. Ten working directories ≈ 4 GB against
765 GB free. Capacity is not the constraint; a budget flag is hygiene, not necessity. How many
entries you actually need is decided by the wire-order analysis under "Staying compatible with
the Qwen Code fork" — possibly just one.

Read cost, from the same measurements: 72–112 ms for a 34.8k-token blob, against ~97 s of
prefill. Even at NVMe-cold speeds this is three orders of magnitude.

---

### Flush on shutdown — required, not optional

`prompt_save` only ever runs from two places: task launch (`server-context.cpp:1691`) and the
idle-slot sweep (`:2463`, which needs `--cache-ram` — `:1474`). **Nothing saves at exit.** A
server that prefills a warm request and then receives nothing else never persists it.

In practice Qwen Code covers this by accident — its `fastModel` / `compactionModel` requests fire
within about a second of the first response, and the sweep they trigger saves the warm slot. That
is not something to depend on. `llama.service` is `PartOf=graphical-session.target` and restarts
at every login, so add an explicit SIGTERM handler that saves every idle slot and flushes the
write-through queue. Without it the tier persists whatever happened to be swept, which is a
coin toss.

---

## Staying compatible with the Qwen Code fork

Checked against `~/code/qwen-code`, branch `warm-startup-prompt` (`cd5dacb984`), and the live
`~/.qwen/settings.json`.

### The client sends nothing cache-related, and that is the good outcome

`prompt_cache_key`, `prompt_cache_options` and the explicit breakpoint markers are all gated
behind `isOfficialOpenAIEndpoint()` (`pipeline.ts:1010-1018`), which requires the base URL's
hostname to be literally `api.openai.com` (`prefix-caching.ts:34-47`). This box is configured
`authType: openai`, `baseUrl: http://127.0.0.1:8080/v1`, so that check is false and the fields
never reach the wire. Nor does the client ever send `cache_prompt`, `n_keep`, or `id_slot` — it
has no concept of them.

Three consequences, all favourable:

- **Server-side content-derived keying is the only option**, which is what §5 of the plan already
  argued for on security grounds. There is no client key to honour and none to collide with.
- **Issue #24746 cannot bite.** The client never names a slot, so requests never take the
  explicit-slot path that skips `prompt_save` / `prompt_load` entirely.
- **No client change is needed for the disk tier**, and it works for `curl`, the ASR work in
  `voice-asr.md`, or anything else pointed at the server.

Note what this also means: the `prompt_cache_key = "qwen-code:<sessionId>"` that upstream
already ships would have been useless here even if it were sent — `sessionId` is fresh per
launch, so a key-based cache would miss on exactly the case this whole exercise is about.

### The warm request needs no special case

`warmStartupPrompt()` (`client.ts:471+`) goes through `runForkedAgent`'s cache path with
`preserveTools: true` and `maxOutputTokens: 1`. On the wire that is an ordinary streaming
`/v1/chat/completions`, so the server sees `SERVER_TASK_TYPE_COMPLETION` and it flows through the
same `get_available_slot` → `prompt_save` / `prompt_load` path as everything else. The disk tier
does not need to know the warm request exists.

The client-side invariant stays as it was: `preserveTools: true` is load-bearing and fails
silently. Nothing in the server change touches that, and the unit test owed for it (item 6.2 of
`TODO.md`) is still owed.

### What is volatile in the prefix — this sets the hit rate

The startup prompt is not byte-stable across all launches. Three sources, worst first:

| source | where | effect |
|---|---|---|
| `Today's date is ${today}` | `environmentContext.ts:90`, formatted at `:39-46` | **day granularity, no clock time.** Changes at local midnight. |
| `isGitRepository(process.cwd())` | `prompts.ts:415` | injects a ~350-token `# Git Repository` block into the system prompt — `$HOME` is not a repo, most project directories are |
| directory context (cwd + folder structure) | `getDirectoryContextString`, inside the startup reminder | varies per working directory |

Qwen Code already orders what it controls deliberately for this — `environmentContext.ts:516-518`:

> Stable parts first (MCP, skills, startup) so prefix-caching servers retain the KV-cache for the
> shared prefix. Deferred-tools is last because tool_search revelations change it — only the tail
> recomputes.

### Where the volatile bytes actually land, on the wire

Read off the live chat template (`GET /props` on the running server), because the Jinja template,
not the client, decides the final order. For this model it emits:

```
<|im_start|>system
# Tools ... <tools> {every tool schema} </tools> ... <IMPORTANT>...</IMPORTANT>
\n\n {the Qwen Code system prompt, including the # Git Repository block}
<|im_end|>
<|im_start|>user
{the startup reminder: MCP, skills, date, directory, deferred tools}
...
```

**The tool schemas come first, ahead of everything volatile.** All three volatile sources land
after them. That is the opposite of what you would guess from reading the client alone, and it is
the single most important fact for keying this cache.

### Which means the fixed-boundary snapshot from §5 of the plan is the right design, for a reason

§5 proposed checkpointing at a fixed boundary (e.g. the first 32,768 tokens) and hashing exactly
those tokens, on the grounds that the restored state is then a true prefix by construction. The
wire order says that boundary can be placed **inside the tool block, before the first volatile
byte** — at which point one entry serves *every* directory on *every* day. Not one entry per
directory per day. One entry.

This also resolves why the shared prefix is worth nothing today. A RAM cache entry holds the
recurrent state as of the *end* of its token list. Reusing the first 30k tokens of a 34.8k entry
would need the state as of token 30k, and for the 31 SSM layers that is not recoverable by
truncation — hence `README.md`'s asymmetry (append a suffix: 86% reused; change something
mid-prompt: nothing reused) and hence #22384 / #20225. A snapshot taken *at* the boundary has no
such problem, because nothing needs rewinding.

The cost is that the tier must **create** that snapshot rather than opportunistically copy one:
prefill exactly the first N tokens, call `llama_state_seq_get_data_ext` there, persist, then
continue the request forward. That is extra work on the write path and it is the part of this
design that is genuinely new code rather than plumbing. Sizing at N = 32,768: 62.8 MiB floor +
32,768 × 10.65 KiB ≈ **399 MiB, total, for the whole machine.**

**Caveat, and it is a real one:** this rests on the tool schemas being byte-stable across
directories. They may not be — a project-local `.qwen/settings.json` adding MCP servers changes
the tools array, and that is upstream of everything. Worth a direct check before committing to a
boundary: capture the rendered prompt from two directories and diff them (`--verbose` on the
server, or the `cache-probe.py` harness in `warm-tests/`). If the tool block does vary, fall back
to one entry per (tools × git-ness × directory × day) at ~425 MiB each — still affordable against
765 GB free, but then LRU eviction by mtime against a byte budget is load-bearing, since a day
rollover strands yesterday's entries rather than overwriting them.

### The background agents — not compaction, and not small

*Corrected 2026-08-10. An earlier draft of this section called these "short background
requests" from `fastModel` / `compactionModel`. Both halves were wrong.*

Captured directly by pointing the client at a logging endpoint that returns a canned reply, so
no GPU was spent and nothing is inferred. After each turn Qwen Code fires **background agents**,
on by default:

| agent | setting | default | seen as |
|---|---|---|---|
| memory extraction | `enableManagedAutoMemory` | **true** | 4 messages, 4 tools (`read_file`, `grep_search`, `glob`, `list_directory`), prompted to write into the USER vs PROJECT memory directories |
| follow-up suggestions | `enableFollowupSuggestions` | **true** | UI-gated, so it fires interactively but not under `-p` |
| memory consolidation ("dream") | `enableManagedAutoDream` | **true** | periodic |
| speculative execution | `enableSpeculation` | false | off |
| auto-skill review | `enableAutoSkill` | false | off |

These are the 10,136 and 15,524-token prefills the journal shows landing immediately after each
main turn. They are smaller than the 41.6k startup prompt for one reason: **4 tools instead of
59.**

**Which is exactly what makes them expensive.** The chat template emits the tool block *first*,
ahead of everything (see the wire-order section above). A request carrying 4 tools diverges from
one carrying 59 within the first few dozen tokens, so a background agent shares essentially
**nothing** with the main turn's cache — and neither can seed the other. Every one is a cold
10–15k prefill, after every turn, at 220–350 t/s. That is 30–70 s of GPU per turn spent on work
the user never sees.

Two consequences:

- **For the disk tier:** a `MIN_TOKENS` floor is still right, but not because these are small —
  they are not. It is because they are a *different prefix family* that would otherwise occupy
  entries and evict the one that matters. `llama-slot-save.sh`'s `MIN_TOKENS=20000` happens to
  sit above both, which is a reasonable starting point for the same reason.
- **For `-np 1`:** these now serialise. If a turn is sent while a background agent is running,
  it queues behind up to ~25k tokens of prefill instead of contending with it. In the common
  case — a cached turn that would have returned in ~1 s — that is a real regression, bounded by
  how long the background work has left. It is usually absorbed by the time spent reading the
  previous answer, but not always. Turning the two default-on agents off removes the question
  entirely, at the cost of the features.

---

## Do this first: the cheap experiment

Before writing any C++. The source read reopened the slot-restore question, and it left exactly
two variables that p14 has **never** varied — both of which are in the running unit:

| variable | why the source implicates it |
|---|---|
| `-kvu` (unified KV) | with `kv_unified`, the idle-slot sweep at `server-context.cpp:2463` calls `prompt_save()` and then `prompt_clear()` on every non-processing slot at every task launch — `prompt_clear()` does `mem.seq_rm(id, -1, -1)`, wiping the restored KV. `[TAG_IDLE_SLOT_CLEAR]` |
| `--spec-type draft-mtp` | the slot API saves and restores `ctx_tgt` only (`server-context.cpp:2606`, `:2644`). The RAM prompt cache saves **both** `main` and `drft` (`server-context.cpp:272-276`). A restored slot has a full target KV and an empty draft KV. |

> **Superseded 2026-08-11 — both rows below are disproven.** Step 2 eliminated `-kvu`,
> `--spec-type draft-mtp` and quantized KV empirically, and the `-kvu` mechanism was wrong
> mechanically as well (the sweep cannot touch the only slot at `-np 1`). The real cause is the
> empty `prompt.checkpoints` list. Kept here for the reasoning trail.

The third-party proxy that reportedly works on this exact model
([writeup](https://ai-muninn.com/en/blog/kv-cache-disk-restore-7x)) runs `--parallel 1` and
restores immediately before each request rather than once at boot — it does not run MTP
speculative decoding, and does not mention `-kvu`.

**One of its three conditions is now free.** `-np 1` became the production setting on
2026-08-10 for unrelated reasons (the warm race, item 6 of `TODO.md`), so the unit already
matches `--parallel 1`. That leaves `-kvu` and `--spec-type draft-mtp` as the only untried
variables, and makes the first retest a zero-config one: just run the scripts against the
server as it stands.

### ✅ Step 1 run 2026-08-10 — restore is **still inert** at `-np 1`. The fork is the route.

`warm-tests/slot-restore-probe.sh`, ~7.8k-token prefix, run-unique nonce, build `b458-7a57bed`:

| step | time | cached |
|---|---|---|
| cold | 15.22 s | 0 / 7,757 (0.0%) |
| **control** — same request, live server | **0.43 s** | **7,753 / 7,757 (99.9%)** |
| save slot 0 | 302 ms | 150,447,016 bytes on disk |
| *restart `llama.service`* | | |
| restore slot 0 | **10.6 ms**, `n_restored=7757` | |
| **resend immediately after restore** | **15.16 s** | **0 / 7,757 (0.0%)** |

The control is what makes this readable: the prefix matcher reuses 99.9% of this exact prompt on
a live server, so the restored slot is not "failing to match" — it is invisible. And 15.16 s
against a 15.22 s cold run is not partial reuse, it is *no* reuse: bit-for-bit the cold path.

**`-np 1` was the most promising of the three untried variables** — it is what the working
third-party proxy runs, and this probe also supplied its other two conditions (restore
immediately before the request, and a `cache_prompt` / `n_keep: -1` variant). It changes
nothing. `-kvu` and `--spec-type draft-mtp` are what remain.

So the cheap route is closed: **there is no proxy or `ExecStartPost` that makes this work on the
production configuration.** The L2 tier under `server_prompt_cache` is the route, and it does not
touch this path.

**What the restore *did* prove — the economics are real.** It read 143 MiB back in **10.6 ms**
(13.2 GiB/s, page cache) against a 15.16 s cold prefill of the same state. If the bookkeeping
worked, that is **1,430×**. The bytes are fine; only the bookkeeping is missing, which is exactly
what the `server_prompt_cache::load` path already gets right.

**The sizing formula is confirmed to 0.001%.** Predicted from `README.md`'s 62.8 MiB floor +
10.65 KiB/token: 150,445,312 bytes. Measured: 150,447,016. A 1,704-byte error on 143 MiB. The
capacity planning in this document can be trusted.

#### Two probe caveats, so the next run is not misread

- **The fourth line of the probe output is confounded and proves nothing.** It reported 99.9%
  cached — but from the RAM cache the *third* request had just populated, not from the restore.
  A `cache_prompt` / `n_keep` arm needs its own restart; as written it can only ever pass.
- **Its 132.59 s was queueing, not work.** The journal shows it sat behind an unrelated
  41,585-token Qwen Code prefill (125.7 s) and then did 4 tokens in 404 ms. Accidental, and an
  exact live demonstration of the `-np 1` trade-off recorded above: one slot means a small
  request can wait behind a large one. Worth remembering when a timing looks impossible.

~~Remaining step, if anyone wants to close it out: re-run against a server started **without
`-kvu` and with `--spec-type none`**.~~ **Done — see Step 2 below.** Both variables are
eliminated, and so is a third this document never listed. Note `llama-slot-restore.sh` still
carries `MAX_SLOTS=2` and a comment claiming `-np 2` — stale, and staler now.

### ✅ Step 2 run 2026-08-11 — root cause found: **the restore never repopulates `prompt.checkpoints`**

Harness: `scratchpad/slot_probe.sh` (own server on :8082 with `-v`, so `llama.service` config is
never edited; ~5.2k-token prefix, run-unique nonce, build 458 via the `_run` wrapper so the
bundled driver is in play). Four flag variants, each dropping one suspect:

| variant | cold | control (live RAM) | after restore |
|---|---|---|---|
| production (`-kvu`, q8_0 KV, `draft-mtp`) | 10.18 s / 0.0% | 0.16 s / **99.9%** | 10.19 s / **0.0%** |
| without `-kvu` | 10.15 s / 0.0% | 0.15 s / **99.9%** | 10.25 s / **0.0%** |
| f16 KV (no `--cache-type-*`) | 10.13 s / 0.0% | 0.16 s / **99.9%** | 10.10 s / **0.0%** |
| without `--spec-type draft-mtp` | 9.89 s / 0.0% | 0.15 s / **99.9%** | 9.84 s / **0.0%** |

**All four fail identically.** The f16 arm wrote 172,239,440 bytes against q8_0's 122,401,928, so
the KV type demonstrably changed and the result did not. This is unconditional, not
configuration-dependent.

**The `-v` log names the mechanism.** From `slot-P_production-post.log`:

```
selected slot by LCP similarity, f_sim_best = 1.000 (> 0.100 thold), f_keep = 1.000
new prompt, n_ctx_slot = 262144, n_keep = 0, task.n_tokens = 5185
forcing full prompt re-processing due to lack of cache data
    (likely due to SWA or hybrid/recurrent memory, see PR#13194)
cached n_tokens = 0, memory_seq_rm [0, end)
```

The chain, with cites into `7a57bed`:

1. Restore loads cleanly — `n_restored=5185`, byte count returned exactly.
2. Slot selection **succeeds perfectly**: `f_sim_best = 1.000, f_keep = 1.000`. This settles the
   open question from §"The observation that led there" — the token list *is* populated. It also
   means `f_keep >= 0.5`, so `update_cache` stays false and **neither `prompt_clear()` fires**.
3. `n_past` = LCP = 5181 > 0, so `server-context.cpp:~3355` enters the SWA/hybrid guard
   `if (pos_min >= pos_min_thold)`, where
   `pos_min_thold = max(0, pos_next - n_swa - (has_new_tokens ? 0 : 1))`.
4. It searches for a usable context checkpoint over `slot.prompt.checkpoints`. The list is
   **empty**, so `find_if` returns `rend()` and `do_reset = true`.
5. `pos_next = 0; n_past = 0;` — the "forcing full prompt re-processing" line above.
6. `cached n_tokens = 0, memory_seq_rm [0, end)` at `server-context.cpp:3442` throws the restored
   KV away.

**Why the RAM cache hits 99.9% and the disk restore gets 0% — one asymmetry.**
`server_prompt` is `{ server_tokens tokens; std::list<common_prompt_checkpoint> checkpoints; }`:

| path | what it repopulates |
|---|---|
| `server_prompt_cache::load` (`server-task.cpp:1812`) | `prompt = std::move(it_best->prompt)` — tokens **and checkpoints** |
| `SERVER_TASK_TYPE_SLOT_RESTORE` (`server-context.cpp:2652`) | `prompt.clear(); prompt.tokens.insert(tokens)` — **tokens only** |

That is the whole bug. It is precisely the "bookkeeping the slot path is suspected of getting
wrong" this document predicted, now named: it is the checkpoint list, not the KV or the tokens.

**Correction — the `-kvu` theory in the table above is wrong, and was wrong mechanically.**
`[TAG_IDLE_SLOT_CLEAR]` sits behind `if (!slot.is_processing())` inside the sweep that runs
*after* `launch_slot_with_task`. At `-np 1` the only slot is the one that just took the task, so
that sweep can never touch it. The `--spec-type` theory is also dead: the draft KV being empty is
not what stops reuse.

**Consequence for the design above: unaffected and now positively justified.** The L2 tier under
`server_prompt_cache` inherits checkpoints for free, which is exactly the property the slot API
lacks. The seam was chosen for the right reason.

**But a second, smaller route now exists.** Persist the checkpoints alongside the slot snapshot —
`common_prompt_checkpoint` (`common/common.h:1112`) is `{n_tokens, id_task, pos_min, pos_max,
data_tgt, data_dft, data_spec}`: four scalars and three `vector<uint8_t>`. A companion file beside
the `.bin` makes `llama-slot-restore.sh` and its `ExecStartPost` work as originally written, with
no new flags and no new cache tier.

~~One detail makes this cheap: the predicate accepts `cur.pos_min < pos_min_thold ||
cur.pos_min == 0`, so a single checkpoint with `pos_min == 0` always qualifies, and one would have
to be created deliberately at save time.~~ **Wrong — corrected 2026-08-11 by measurement.**
`pos_min == 0` is only the *second* arm of that `||`. With `n_swa = 0` and `has_new_tokens = 0`,
`pos_min_thold = pos_next - 1` — i.e. just below the end of the prompt — so the **ordinary**
checkpoints qualify on the first arm: the observed hit selected `pos_min = 5178` against
`pos_min_thold = 5182`. Nothing has to be created; persisting the checkpoints the server already
makes is sufficient, which is what was implemented.

This is also a genuine upstream bug worth filing either way: *slot save/restore drops context
checkpoints, so a restored slot always full-reprocesses on SWA / hybrid / recurrent models.*
Qwen3.6-35B-A3B is gated delta-net, hence hybrid — which is why this box sees it and a
pure-attention model would not.

**The economics are unchanged and still the point.** 143 MiB read in 10.6 ms against a 15 s cold
prefill of the same state — ~1,430× — now with a known reason it was not landing.

---

## Building it — from the build that is running now

The whole point is to change the server and change nothing else, so that any performance
difference afterwards is a bug rather than a variable. Three things fix the baseline.

### 1. The exact commit

The running binary reports `version: 458 (7a57bed)`. That resolves in the fork to
**`7a57bedaaed7`** (2026-08-05, *"Merge remote-tracking branch 'upstream/master' into
shv-upstream-merge"*). Branch from that, **not** from the `strix-halo-vulkan` tip, which has since
moved to `3be50ccc22` (2026-08-09) and carries at least one llama-core change
(*"fix reshaped-tensor row stride for block-quantised types"*).

llama.cpp derives its build number from git, so **the build printing `458` again is the check
that you branched from the right place.** If it prints anything else, stop.

The prompt-cache code is stable across this window, which is what makes the patch portable
later: at `7a57bedaaed7`, `server-task.cpp`, `server-task.h`, `server-common.cpp` and
`server-common.h` are byte-identical to current upstream master, and the 36-line drift in
`server-context.cpp` is all speculative-decoding and backend-sampling work.

### 2. Only step 3 of `BUILD.md` is needed

Mesa RADV and libdrm are **runtime** driver bits, already sitting in
`/opt/llama/strix-toolbox/vulkan/driver/` (Mesa 26.3.0-devel + libdrm 2.4.134). The patch does not
touch them and they must not be rebuilt — `TODO.md` item 4 closed the question of which Mesa to
use, and system Mesa (26.0.3) is the one genuinely slow option.

### 3. Install in parallel, and keep the wrapper

`README.md` measures the `_run` wrapper as worth **~8%**, and the unit already launches through it
(`ExecStart=.../vulkan/llama-server` is a symlink to `_run`). What the wrapper does — read it, it
is 25 lines — is point `VK_ICD_FILENAMES` / `VK_DRIVER_FILES` at the bundled RADV manifest and
prepend `driver:bin` to `LD_LIBRARY_PATH`. Reproduce that layout exactly:

```bash
NEW=/opt/llama/strix-toolbox-diskcache/vulkan
sudo mkdir -p "$NEW"
sudo cp -a /opt/llama/strix-toolbox/vulkan/driver "$NEW"/          # bundled Mesa + libdrm, unchanged
sudo cp -a /opt/llama/strix-toolbox/vulkan/_run   "$NEW"/
sudo ln -s _run "$NEW"/llama-server; sudo ln -s _run "$NEW"/llama-bench
sudo cp -a build-vk/bin/. "$NEW"/bin/                              # the newly built binaries + libs
```

A parallel tree means the working install stays bootable and the A/B is one line in the unit.

The `GGML_VK_*` knobs the wrapper exports have been build defaults since fork commit `0b29b30`
(2026-07-30), which is an ancestor of `7a57bed`, so a build from that commit already has them on.

### Toolchain

Already in place on this box, including the part `BUILD.md` warns about:

| requirement | on p14 | |
|---|---|---|
| current `glslc` (shaderc ~2026.x) | shaderc **2026.1** | ✅ the distro-2023 trap does not apply |
| Vulkan + SPIRV headers | libvulkan-dev 1.4.341, spirv-headers 1.4.341 | ✅ |
| cmake | 4.2.3 | ✅ |
| g++ | 15.2 (shipped build used 13.3) | ✅ |
| ninja / ccache | absent | optional — `make -j` works, but install both, the shader build is long |

```bash
git clone https://github.com/Nathanw1014/llama.cpp ~/src/llama.cpp
cd ~/src/llama.cpp && git checkout -b disk-cache 7a57bedaaed7
cmake -B build-vk -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DLLAMA_CURL=OFF
cmake --build build-vk --target llama-server -j
```

**Verify the driver before believing any number.** `BUILD.md` documents the failure that silently
falls back to CPU: `llama-bench -ngl 99 -p 128 -n 8 -r 1` must print a
`ggml_vulkan: 0 = ... RADV STRIX_HALO` line and read `Vulkan`, not `CPU`, in the backend column.
That is a ~7× difference and it does not announce itself.

**Benchmark under the doc's power state or the numbers are meaningless:** `sudo ~/p14/set-dpm-high.sh`
plus GNOME Power Mode → Performance. See `TODO.md` items 2 and 5 — that is worth ~70% and ~10%
respectively, far more than anything measured here.

---

## Honest scope note

Item 6 of `TODO.md` already removed the *latency* case for this. With warm-on-startup working in
the Qwen Code fork, a launch spends its first ~97 s prefilling in the background while the user
reads their notes; the disk tier replaces that background GPU with a ~100 ms disk read. **That is
heat and battery on a power-bound laptop, not a faster first turn** — unless you habitually start
typing within ten seconds of launching, in which case it is both.

Nothing here changes that judgement. It is a good piece of engineering with a modest and
correctly-characterised payoff, and it is worth building on those terms rather than on an
expectation of an 11× that has already been collected elsewhere.

The one thing that would change the calculus: this tier works for **any** client, not just the
forked Qwen Code, and it survives the `llama.service` restart that happens at every login — which
warm-on-startup does not.

---

## Implemented 2026-08-11 — `--cache-disk-path`, and it works

Built on the fork, branched from the running build's commit as §"The exact commit" requires:
**https://github.com/jstormes/llama.cpp**, branch `p14/disk-prompt-cache`
(`52682e8d1` then `6f355f044`, both on top of `7a57bedaa`, so the build still reports 458).
Local worktree: `~/code/llama.cpp-458`, build dir `build/`.

**`p14/disk-prompt-cache` is the fork's default branch** (set 2026-08-11), so a fresh clone lands
on it rather than on upstream master. Two consequences: `gh pr create` from inside that clone
defaults its *base* to this branch, so pass `--repo` and `--base` explicitly when sending a PR to
`Nathanw1014/llama.cpp` or `ggml-org/llama.cpp`; and in `~/code/llama.cpp` the remote for it is
named `fork`, not `origin` — `origin` is still `Nathanw1014/llama.cpp` and `upstream` is
`ggml-org/llama.cpp`, kept that way on purpose.

### What shipped

| flag | default | meaning |
|---|---|---|
| `--cache-disk-path DIR` | disabled | persist prompt-cache entries here, reload them at startup |
| `--cache-disk-min-tokens N` | 0 = all | only persist prompts at least this long |
| `--cache-disk-max-entries N` | 4, 0 = unlimited | prune to newest N by mtime after each write |

Also: slot save/restore now persists `prompt.checkpoints` to a `<snapshot>.ckpt` companion, which
is the bug fix from §"Step 2"; and each entry's header carries a config fingerprint (model path,
KV types, `n_ctx`, `n_ubatch`, `kv_unified`, speculative config) so a changed configuration is
discarded rather than fed to a mismatched context.

### The design survived, with one simplification and one correction

**Simplification — no key design was needed.** §5 worried about server-computed keys and
caller-supplied filenames. `server_prompt_cache::load()` already selects the best entry by
`f_keep`/`f_sim` across `states`, so the disk tier only has to persist entries and reload them all
at boot; the existing matcher does the selection. Filenames only need to be unique.

**Correction — no boundary snapshot had to be created.** §5's "genuinely new code" was prefilling
exactly N tokens to produce a true-prefix snapshot. Unnecessary: the server already creates
checkpoints every 8,192 tokens, and those are exactly the rewind points needed. Persisting them is
plumbing, not new design.

**Both traps in §"Where the bytes get filled" were real and are respected.** The write happens
after `llama_state_seq_get_data_ext` fills the buffers, not in `alloc()` — hooking `alloc()` would
persist zeros. And it is write-through, not evict-time, because `load()` erases the entry it
returns.

### Measured

| | result |
|---|---|
| slot restore, before/after the checkpoint fix | 10.01 s at 0% cached -> **0.17 s at 99.9%** |
| one session's write-through | 4 entries, 1994.5 MiB |
| reload at next start | **4 entries, 0 discarded, ~0.8 s** (12.64 s -> 13.43 s in the boot log) |
| boot cost | 15 s with the cache vs 14 s without |

A ~41.6k-token prefix is therefore in the RAM cache **before the first request** — the state that
previously only existed after paying for it.

### Two things this got wrong on the first attempt

**No ceiling.** v1 persisted every prompt with no budget and reached **10 GB across 19 files in
~13 minutes**. Eleven were background requests (829–15,651 tokens); eight were near-identical
variants of the same startup prompt at ~800–960 MiB each. Hence `--cache-disk-min-tokens` and
`--cache-disk-max-entries`.

**Keying on the whole token list.** The startup prompt varies by a few tokens between launches, so
every variant hashes differently and gets its own ~900 MiB file. `max-entries` bounds this but does
not fix it. The fix is §"fixed-boundary" keying — hash `tokens[0..K)` below the first volatile
byte, or port `alloc()`'s prefix-subsumption to disk (an index of on-disk token lists is ~166 KB
per entry, so this is cheap). Deferred deliberately: the ceiling was what was actually needed, and
`max-entries 4` means a stale entry ages out on its own.

### Still open

1. **A save reported 3 checkpoints where the restore read back 2.** Harmless — reverse iteration
   finds the newest qualifying one first — but unexplained, and it should not ship in a PR.
2. **The config fingerprint is untested.** It compiles and the counter is wired, but no run has
   changed a config against a populated directory. Two-minute check: start once with
   `--cache-type-k f16` and confirm the entries are discarded.
3. **Divergent-prompt reuse is unmeasured.** The reasoning says a prompt diverging at ~30k should
   rewind to the checkpoint at 24,576 and reuse that much. Not yet verified, and the whole
   value proposition across day/directory changes rests on it.
4. **`__P14_DIAG__` instrumentation is still in the commit** and must come out before any PR.
5. **No disk budget in bytes** — only an entry count, so the ceiling is `max_entries × entry size`.

### Note on the §"Honest scope note" above

That section's judgement still holds and is worth re-reading: the latency case was already
collected by warm-on-startup, and what this tier adds is surviving the restart that happens at
every login, for any client. What it does *not* add is a faster first turn on a launch where the
warm had time to run.
