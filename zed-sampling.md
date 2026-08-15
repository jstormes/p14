# Sampling parameters for Zed's llama.cpp provider — what changed and why

*2026-08-14. Fork work on `zed-industries/zed`, branch `prompt-fixes` on
`github.com/jstormes/zed`, plus a one-line fix to `llama.cpp` on
`p14/disk-prompt-cache`.*

**Read first:** `disk-cache.md` for the prompt-cache mechanics this builds on, and
`~/code/llama.cpp-458/todo/repetition-penalty-alias.md` for the upstream issue that came out
of it.

Written up for a blog post / video script later, so it keeps the wrong turns in. The wrong
turns are most of the useful content — three separate times a test said the opposite of the
truth, and each one would have shipped a false conclusion.

---

## What this started as, and what it became

The ask was small: let a user set `top_p`, `top_k`, and `min_p` alongside `temperature` for a
local model. It ended up touching four separate things, because pulling on the first one
exposed the next.

| # | change | why it appeared |
|---|---|---|
| 1 | Freeze the system prompt's date per thread | Found while reading how the prompt is built |
| 2 | Add `top_p`, `top_k`, `min_p` | The original ask |
| 3 | Make Zed's thinking toggle actually work | Discovered mid-way: it was inert on this provider |
| 4 | Per-profile sampling + a UI to edit it | Asked for once #2 existed |
| 5 | `repetition_penalty` alias in llama.cpp | The penalties work surfaced a silent-drop bug |

Commits on `prompt-fixes`, oldest first:

```
744b3d99d1  Add fork-local Claude Code scaffolding for llama.cpp work
3a3c7bbd07  agent: Capture the system prompt's date once per thread
fb371c4830  llama_cpp: Add top_p, top_k, and min_p, and honor the thinking toggle
622631d446  agent: Add per-profile sampling parameters and a UI to edit them
ff4c6a3d6e  docs: Use sourced sampling values for the llama.cpp examples
4155aed359  llama_cpp: Add presence and repetition penalties
```

llama.cpp: `b746971b5` on `p14/disk-prompt-cache` (cherry-picked from `37b59dcef` on
`v0.6.1-bench`).

---

## 1. The date was breaking the prompt cache once a day

`SystemPromptTemplate` is rebuilt and rendered inside `build_request_messages_until` on **every
completion request** — not once per thread, not once per turn. A turn with three tool-call round
trips renders it three times. One of its fields was:

```rust
date: Local::now().format("%Y-%m-%d").to_string(),
```

The rendered system prompt is message zero, so it is the start of the prefix `llama-server`
matches on. A thread alive across local midnight changed its own prefix and invalidated the
cache for the **whole conversation**, not just the tail.

Fix: capture the date when the thread is constructed, reuse it. `from_db` captures at resume
time rather than persisting the original, so a thread reopened weeks later still reports the
right day. +38/−1 in `crates/agent/src/thread.rs`.

**This is not provable by test on any given day.** `date` only moves at midnight, so a fixed and
an unfixed binary produce identical output right now. The test asserts the *mechanism* instead —
it sets `thread.date` to a sentinel and checks the rendered prompt carries it, which fails
immediately if anyone reverts to reading the clock.

### Measured: the cache is worth protecting

Two turns in one thread, captured through the proxy:

| | turn 1 (cold) | turn 2 |
|---|---|---|
| prompt tokens | 2489 | 2510 |
| `cache_n` reused | 0 | **2485** |
| `prompt_n` prefilled | 2489 | **25** |
| prefill time | **6282 ms** | **1253 ms** |

99.0% reuse, 5 seconds saved on one short turn. On a 250k-token context the same break costs
proportionally more.

---

## 2. The samplers themselves

Four layers, and the shape matters because each one is a place the value can silently vanish.

```
settings_content/src/agent.rs      newtypes + doc comments + schemars ranges
language_model_core/src/request.rs SamplingParameters + flat request fields
agent_settings/src/agent_settings  the lookup
llama_cpp/src/llama_cpp.rs         the wire struct        ← both edits
language_models/.../llama_cpp.rs   the request builder    ← required
```

`crates/llama_cpp/.rules` already warned about the last pair: *"Adding a field takes two edits…
A field added in one place without the other silently sends nothing."*

### Three decisions worth defending

**Newtypes, not raw `f32`.** `#[serde(transparent)]` keeps the JSON byte-identical, so no user
settings change, but the type carries its documented range and gives a future settings UI a
clamping hook for free.

**`#[schemars(range(...))]`, not just prose.** Newtypes alone document a range; they do not
enforce it. Clamping lives in the graphical settings widget, which this work does not use. The
schemars attribute puts real `minimum`/`maximum` into the JSON schema, so the language server
flags an out-of-range value as you type in `settings.json` — the surface people actually use.

**`skip_serializing_if = "Option::is_none"` on everything.** A user who configures nothing sends
bytes identical to before the change. Verified against a pre-change capture: key set went back
to exactly `['model', 'messages', 'stream', 'stream_options']`.

### The matching rule is wholesale, and that is a trap

`agent.model_parameters` matching walks the list in reverse and the **first match supplies every
value** — including `None`. It was already like that for `temperature`; the change preserves it
exactly and pins it with a regression test.

Which means the obvious way to write the Qwen config **does not work**:

```jsonc
// WRONG — top_k and min_p are silently lost
{ "provider": "llama.cpp", "top_k": 20, "min_p": 0.0 },
{ "provider": "llama.cpp", "thinking": true, "temperature": 0.6, "top_p": 0.95 }
```

The mode-specific entry matches last and wins outright. Every entry must repeat the shared
values. The card's `top_k: 20` and `min_p: 0.0` are the same across all four of its sets, so
factoring them out is exactly what a reader will try.

---

## 3. Zed's thinking toggle did nothing on this provider

Found while wiring the samplers. `request.thinking_allowed` appeared **zero times** in
`crates/language_models/src/provider/llama_cpp.rs`. Ten other providers read it — Anthropic,
OpenAI, Ollama, Mistral, DeepSeek, Bedrock and more. llama.cpp ignored it entirely, so the model
reasoned according to its own chat template and `"enable_thinking": true` in settings did
nothing at all.

Fix: carry it as `chat_template_kwargs.enable_thinking`, sent only for models whose template
advertises thinking, so models without one keep byte-identical requests.

### Measured: this was the biggest single win

Thread-title generation, before and after:

| | before | after |
|---|---|---|
| duration | **39.819 s** | **1.978 s** |
| reasoning emitted | 3,788 chars | none |

**20×.** Every new thread was paying forty seconds for the model to reason its way to a
seven-word title, because nothing carried "don't think" to the server.

Note this one changes the *rendered prompt*, not just request metadata — so flipping thinking
mid-thread does legitimately invalidate the prompt cache. That is correct behavior: the prompt
genuinely changed.

### Which made a `thinking` discriminator worth having

Reasoning models publish different sampler sets per mode. An optional `thinking: true|false` on
a `model_parameters` entry restricts it to one mode; omitting it matches both, so existing
configs are untouched.

The lookup uses the *same* `thinking_allowed` value the request carries — hoisted into one
binding in `thread.rs` — so the parameters always describe the mode the model actually runs in.
They cannot drift.

---

## 4. Per-profile sampling, and a UI

`agent.model_parameters` is keyed by provider and model. It cannot express "this profile runs
the model differently", and it is only reachable by editing JSON.

Each profile now carries optional sampling, edited from
**profile selector → Configure → *profile* → Configure Sampling**. Combined with the profile's
existing `default_model.enable_thinking`, a profile becomes a complete preset: the thinking mode
plus the parameters that mode calls for.

Precedence here is **per field** — a profile setting only `top_k` keeps the global
`temperature`. That deliberately differs from the wholesale rule *within* `model_parameters`,
because it governs a different boundary. Both are tested.

### The UI took three rounds, all found by using it

This is the part worth dwelling on in a write-up. The feature compiled, passed 1372 tests, and
passed release clippy while being **completely broken for its primary use**.

| round | bug | why tests missed it |
|---|---|---|
| 1 | Values discarded on "Go Back" | Nothing drives the modal in tests |
| 2 | Tab did nothing | Focus behavior is not unit-testable here |
| 3 | Tab escaped the form | Same |

Round 1 was a design error: every other screen in that modal persists as you interact, with no
save step. Requiring Enter meant the natural flow — type, click Go Back — threw the work away.
Fixed by making every exit commit, with a guard so an untouched visit does not rewrite settings.

Round 2: `tab_index` has to go on the **editor's own focus handle**, not a wrapping div, or
focus lands on the wrapper and the editor is unreachable. `mcp_servers_page.rs:993` already had
this, with a comment explaining it.

Round 3: `window.focus_next` walks the whole window's tab order and wraps there, so from the last
field it left the form. `tab_group()` does not help — reading its implementation, it only
renumbers child indices. Cycling has to be explicit.

**Every fix came from finding how Zed already solves it, not from reasoning it out.** The one
time I guessed — Enter-to-save — I broke a convention every sibling screen follows.

### A side effect to know about

Editing sampling on a built-in profile **materializes** it: the whole profile, including its
23-tool list, is copied from `default.json` into your settings. It then stops tracking future
Zed updates to that built-in. This is pre-existing behavior for any tool toggle, and unavoidable
given `name` and `tools` are required fields — but a *sampling* edit freezing your tool list is
surprising.

---

## 5. `repetition_penalty` is silently dropped by llama-server

The Qwen3.6-35B-A3B card recommends `presence_penalty` and `repetition_penalty` in three of its
four sets. Adding them turned up a genuine upstream bug.

`llama-server` accepts the repetition penalty **only** as `repeat_penalty`. Send
`repetition_penalty` and it is dropped as an unknown key: no error, no warning, no effect. The
caller believes the penalty is applied.

That is the name the card uses. It is also
[what vLLM's OpenAI-compatible server accepts](https://docs.vllm.ai/en/v0.9.0/serving/openai_compatible_server.html).
So anyone following the card literally, in any llama.cpp client, gets no repetition penalty and
no clue why.

The fix upstream is one line, and the mechanism already existed —
`tools/server/server-schema.h:38` has `field::add_alias`, already used to accept OpenAI's
vocabulary:

```cpp
add((new field_num("n_predict", params.n_predict))
    ->add_alias("max_completion_tokens")
    ->add_alias("max_tokens")   // same problem, already solved
```

So:

```cpp
add((new field_num("repeat_penalty", params.sampling.penalty_repeat))
    ->add_alias("repetition_penalty")
```

Applied as `b746971b5`, live on `llama-test`. Verified: alias honored, canonical **still**
honored, canonical wins when both are sent. That middle one is the one that mattered — an alias
change could plausibly have inverted precedence and silently broken every existing client.

Zed keeps sending `repeat_penalty`, the canonical name, so nothing on the Zed side needed to
change. Details and the reproduction are in
`~/code/llama.cpp-458/todo/repetition-penalty-alias.md`. Not reported upstream yet; llama.cpp's
`AGENTS.md` requires a human to write the issue text.

---

## Caching, across all of it

The prompt cache was the reason this work started, so every change was checked against it. Three
different relationships, and conflating them is easy.

### What cannot affect the prompt cache

**The samplers.** `llama-server` matches its KV cache on the *tokenized prompt* — the messages
rendered through the chat template. `temperature`, `top_p`, `top_k`, `min_p`,
`presence_penalty` and `repeat_penalty` are applied to the logits **after** prefill. They never
enter the token stream. Changing them mid-thread changes what is generated and re-prefills
nothing.

This is worth stating plainly because `crates/llama_cpp/.rules` says *"the serialized request
must stay byte-identical turn to turn"*, which reads as though any new JSON field is a hazard.
That sentence is a conservative overstatement of the real invariant, which is **prompt-prefix
identity**. The rule is a good guardrail and was left as written, but it should not have blocked
this change and did not.

### What does affect it

**`chat_template_kwargs.enable_thinking`.** This one is different in kind: it is a variable fed
into the model's own chat template, so it changes the **rendered prompt**, not just request
metadata. Flipping thinking mid-thread legitimately invalidates the cache — the prompt genuinely
changed. Documented in `crates/llama_cpp/.rules` alongside the samplers so the distinction is not
lost.

### What was done to keep existing behavior identical

- **`skip_serializing_if = "Option::is_none"` on every new field.** A user who configures nothing
  produces bytes identical to before the change. Verified against a pre-change capture: with
  `model_parameters: []` the body key set went back to exactly
  `['model', 'messages', 'stream', 'stream_options']`.
- **Deliberate field order.** `serde_json` emits in declaration order. Samplers were inserted
  after `temperature` and before `tools`; the penalties after `min_p`. That leaves the entire
  existing body prefix — `model`, `messages`, `stream`, `max_tokens`, `stop` — untouched. Pinned
  by `request_serializes_sampling_parameters_in_a_stable_order`.
- **`chat_template_kwargs` gated on `supports_thinking`.** Models whose template has no
  `enable_thinking` variable have nothing to gate, so their requests are unchanged.

### The prefix hazards still open — verified 2026-08-14, not fixed

The date was one of three fields that vary between renders of the same thread's system prompt.
The other two are still live:

| field | why it varies | where |
|---|---|---|
| `available_tools` | rebuilt every tool-call round trip, no equality check | `thread.rs:4231` `refresh_turn_tools` |
| `user_agents_md` | read fresh from a file watcher on every render | `templates.rs:45` |

`available_tools` is the bigger one by far: `date` broke the prefix once a day, this one can
break it several times **per turn**. The ordering is a `BTreeMap` so it is at least
deterministic, and `ProjectContext` in `agent.rs` already shows the fix shape — compare against
the current value and only push through when it differs.

Note that this session's end-to-end captures ran with `default_profile: "minimal"`, which sends
`tools=0`. That structurally excludes the `available_tools` hazard from every measurement here.
The 99% cache hit is real, but it is a best case: a tool-enabled profile has not been measured.

### Zed still cannot show you a cache hit

`llama-server` reports reuse and Zed throws it away.

The server sends it in two places — verified live on a real streamed response:

```
"timings": { "cache_n": 2485, "prompt_n": 25, ... }
"usage":   { "prompt_tokens_details": { "cached_tokens": 2486 } }
```

But `llama_cpp::Usage` models only `prompt_tokens`, `completion_tokens`, `total_tokens`
(`llama_cpp.rs:220-224`) — no cache field — and the event mapper hardcodes
`cache_read_input_tokens: 0` at three sites in
`crates/language_models/src/provider/llama_cpp.rs` (999, 2177, 2220).

So the proxy is the only way to see whether caching is working. Surfacing this is the obvious
next change: add the field to `Usage`, read `prompt_tokens_details.cached_tokens`, and report it
instead of zero. It is small, it is self-contained, and it would make every measurement in this
document visible from inside the editor.

---

## Three tests that lied

The most transferable content here. Each of these produced a confident wrong answer.

### 1. Empty output made everything look identical

First check of whether the server honors `top_k`/`min_p`: send a request with each, compare
outputs. All identical → "the parameters work, output is deterministic".

Both outputs were `''`. The model is a reasoning model and `max_tokens: 24` was consumed
entirely by the reasoning block, leaving `content` empty. `'' == ''` for every comparison.

Worse, the control in that same run — a deliberately bogus parameter name — also returned
HTTP 200. **The server accepts unknown keys silently**, so a 200 proves nothing at all.

Fix: raise `max_tokens`, disable thinking via `chat_template_kwargs`, and use a prompt whose
output is long enough to differ.

### 2. Absent-vs-present is not a control

Second check, on `presence_penalty`: compare a request without it against one with `2.0`.
Different → honored. Then the same for `repetition_penalty`: identical → ignored. And
`presence_penalty` in one variant of the test: identical → **"ignored"**.

That last one was wrong. Any penalty value turns on the penalties sampler, which shifts output
slightly on its own. Comparing absent against present conflates "this parameter was read" with
"the sampler chain changed".

Fix: compare a **neutral value** against a large one — `presence_penalty: 0.0` vs `2.0`,
`repeat_penalty: 1.0` vs `1.8`. Under that control all three penalties are clearly honored and
`repetition_penalty` is clearly not.

Had the first result been trusted, the conclusion would have been "Zed cannot implement half of
what the card recommends".

### 3. f32 widened to f64 fails an equality check

Hit **three times** in one day, in Rust and in Python. `1.8f32` widens to `1.7999999523162842`.
A verification script printed `alias honored: False` while the underlying data was perfectly
correct.

Compare through the f32: `Some(1.1f32 as f64)`, or `struct.unpack('f', struct.pack('f', 1.8))`.

### And one estimate that was badly wrong

Predicted a near-full rebuild from mtimes — 175 files newer than the binary across 68 crates
including `gpui` and `editor` — and warned it would OOM at `-j 24`.

It took **1m51s** and peaked at 10.8 GB against a 3.7 GB idle baseline. Cargo fingerprints
content and incremental compilation redoes only changed codegen units, not whole crates.

**Do not estimate Rust rebuild cost from file mtimes.**

---

## The configuration this produced — applied 2026-08-14

Everything above is fork work. This is what actually landed in
`~/.config/zed/settings.json` as a result, and the two things about it that are not obvious.

**All five agent profiles carry the same sampling block** — the three built-ins (`write`, `ask`,
`minimal`) plus the two added for MCP (`browser`, `browser-debug`; see `browser-mcp.md`):

```json
"sampling": {
  "temperature": 0.6,
  "top_p": 0.95,
  "top_k": 20,
  "min_p": 0.0,
  "presence_penalty": 0.0,
  "repeat_penalty": 1.0
}
```

These are the **thinking-mode precise-coding** figures from the
[Qwen3.6-35B-A3B model card](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF) — the same set
`docs/src/ai/agent-profiles.md` uses as its sourced example after `4155aed359`. They match
`default_model.enable_thinking: true`, which is what makes the thinking-mode row the right one.

### The key is `repeat_penalty`, and that is section 5 biting again

Model cards say `repetition_penalty`. `llama-server` accepts only `repeat_penalty` and silently
ignores the other spelling — the field comment in `crates/llama_cpp/src/llama_cpp.rs` says so
outright. Copying the card's key name verbatim into settings produces no penalty and no error.

The neutral values are `presence_penalty: 0.0` and `repeat_penalty: 1.0`, so setting them changes
nothing today. **They are pinned anyway, because unset fields fall through to
`agent.model_parameters`.** That list is still `[]` here, so unset currently means "provider
default" — but the card wants `presence_penalty: 1.5` for *non-thinking* mode, and the moment such
an entry is added there, every profile without a pinned penalty silently inherits it. Pinning makes
each profile closed rather than dependent on what `model_parameters` happens to hold.

### Listing a built-in profile merges, it does not replace

The three built-ins are listed with only `name` and `sampling` — no `tools`. That relies on
`MergeFrom` for `IndexMap` walking the *incoming* map only
(`crates/settings_content/src/merge_from.rs`), so an absent `tools` contributes nothing and the
shipped tool list survives. If it replaced instead, `write` would silently lose all 23 of its tools.

**This is not pinned by any test in the fork.** `unmodified_default_detection` sets a user profile
but only asserts the modified flag, never the merged tool list. It was verified here by adding a
temporary `gpui::test` asserting the real case — user settings with `sampling` and no `tools` —
and running `cargo test -p agent_settings`:

```
test tmp_sampling_only_user_profile_preserves_builtin_tools ... ok
```

Built-in tools preserved, `temperature` resolved to `0.6`. The test was then reverted, so the tree
is clean and **the gap is still there**. It is a small, obviously-correct regression test if this
ever goes upstream.

### Not covered by any of this

Profile sampling applies to **agent threads only**. Inline assist, commit-message generation, and
thread titles have no profile and read `agent.model_parameters` directly — still `[]`, so those
three paths remain on provider defaults. Closing that means writing `model_parameters` entries, and
per "The matching rule is wholesale" above, every entry has to repeat the shared values.

Also unverified: no Zed request has been *observed* carrying these values. The chain was traced in
source — `ProfileSamplingContent` → `SamplingParameters` → `LanguageModelRequest` → the llama.cpp
wire struct — but the capture-proxy loop in "How to reproduce" is what would actually prove it, and
it has not been re-run since the profiles were written.

---

## Measured, in one place

| thing | number |
|---|---|
| Prompt cache reuse, turn 2 | 2485 / 2510 tokens (99.0%) |
| Prefill, cold → warm | 6282 ms → 1253 ms |
| Thread-title generation | 39.819 s → 1.978 s (20×) |
| Incremental debug build, 68 stale crates | 1m51s, peak 10.8 GB |
| Build memory cost above idle | ~7 GB, against ~12 GB free with the model loaded |
| `script/clippy`, cold release cache | 3m25s; warm, 1m08s |
| Test suite, 7 crates | 1373 passing |

The build-memory line matters operationally: an incremental debug build **coexists** with the
45 GB model resident. Only release builds and post-`cargo clean` rebuilds need
`systemctl --user stop llama-test`.

---

## How to reproduce the whole loop

The capture proxy is what makes any of this checkable.

```
Zed → :8080 llama-proxy → :8081 llama-server (llama-test.service)
```

```bash
# what Zed actually sent, byte for byte
cd ~/p14/llama-proxy && python3 prompts.py raw -1

# did the prefix hold between two turns
python3 prompts.py diff 373 375

# what the server actually applied — replay a captured body with verbose on
#   add "verbose": true, read __verbose.generation_settings
```

That last technique is the strongest verification available: take a **real captured Zed request**,
replay it, and read back the sampler values the server actually used. It closes the loop
end-to-end without touching the GUI. All six samplers came back matching what Zed sent.

---

## Still open

- **Docs snippets are unvalidated.** `docs_preprocessor` checks every ` ```json [settings] `
  block against the live schema at docs-build time. `mdbook` is not installed here, so the six
  blocks now carrying real values have never been through it. Most likely CI trip point.
- **The upstream issue is unwritten.** llama.cpp's `AGENTS.md` forbids an agent authoring issue
  or PR text. Notes are ready; a human has to write it.
- **`frequency_penalty` works and is not wired up.** Verified honored by the server; nobody asked
  for it.
- **The builtin-profile merge is untested in the fork.** Listing a built-in with only `sampling`
  relies on `tools` merging rather than replacing. Verified once by a throwaway test that was
  reverted; no permanent test pins it. See "Listing a built-in profile merges".
- **The applied sampling has never been observed on the wire.** Traced through the source but not
  captured. Re-running the proxy loop against a profile-driven request would close it.
- **Zed-side `repetition_penalty` alias.** Moot locally now that our server accepts both, but
  anyone on a stock `llama-server` build still hits the silent drop. Worth deciding if this ever
  goes upstream.
- **`available_tools` still breaks the prefix per turn** — the largest remaining caching hazard,
  and the natural next piece of work. `user_agents_md` after it.
- **Cache telemetry is still discarded**, so the editor cannot show a hit rate. Small, contained,
  and it would make this whole document measurable without the proxy.
- **The 99% figure is a best case.** It was measured on a `minimal` profile sending no tools,
  which structurally excludes the `available_tools` hazard. A tool-enabled profile is unmeasured.
