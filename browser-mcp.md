# Browser and JS-debug MCP — the Claude Code and Zed stack, 2026-08-14

Companion to the `## Client ops — 2026-08-12` section of `README.md`, which covers the **qwen-code**
Playwright MCP setup. This file covers two more clients — **Claude Code** (`~/.claude.json`) and
**Zed** (`~/.config/zed/settings.json`) — and a wider brief: browser testing *and* JavaScript
debugging.

Two things here are worth more than the setup steps, and each has its own section:

- **All three clients share one global npm install and one browser cache.** That coupling is the
  least obvious failure mode on this box.
- **Zed prices these tools an order of magnitude higher than the other two clients do.** Measured
  against the running server's `/tokenize`: **17,626 tokens, ~42% of the ~41.6k startup prompt.**
  That is the single largest prompt regression this project has measured, and it is the reason the
  Zed setup is built around profiles rather than global enablement.

---

## What was asked

Two things: the best MCP for browser testing, and a JavaScript debug MCP.

The answer is that **no single server does both**, and the second one is the weak half of the
ecosystem. Three servers now cover it:

| server | version | job |
|---|---|---|
| `playwright` | `@playwright/mcp@0.0.79` | drive and test — deterministic, cross-browser, emits real Playwright code |
| `chrome-devtools` | `chrome-devtools-mcp@1.7.0` | diagnose — console, network, perf traces, Lighthouse, heap snapshots |
| `js-debugger` | `@debugmcp/mcp-debugger@0.23.0` | breakpoints — step, inspect variables, evaluate in frame |

All three are stdio servers, globally installed, launched by their own binary. Verified
`✔ Connected` via `claude mcp list`.

## The starting state was broken, and the default was hiding it

The Claude Code config as found:

```json
"playwright": {
  "command": "npx",
  "args": ["-y", "@playwright/mcp@0.0.79", "--isolated", "--headless"]
}
```

This worked. It should not have — and understanding why is the useful part.

**The browser cache was version-mismatched.** `~/.cache/ms-playwright/` held `chromium-1234` and
`chromium_headless_shell-1234`, but the pinned `@playwright/mcp@0.0.79` bundles
`playwright-core` **1.63.0-alpha-2026-08-05**, whose `browsers.json` requires revision **1237**. A
direct launch fails outright:

```
browserType.launch: Executable doesn't exist at
~/.cache/ms-playwright/chromium_headless_shell-1237/chrome-headless-shell-linux64/chrome-headless-shell
```

**It worked anyway because `--browser` defaults to the `chrome` *channel*, not bundled Chromium.**
So the server was driving `/opt/google/chrome/chrome` — system Google Chrome 151.0.7922.108 —
and never touched the 656 MB of downloaded browsers at all. Confirmed by reading the live process
tree during an MCP call, not inferred:

```
/opt/google/chrome/chrome --headless --no-sandbox ... --user-data-dir=/tmp/playwright_chromiumdev_profile-...
```

That is a bad state for a test suite: the browser under test was an auto-updating desktop Chrome,
and 656 MB of pinned, reproducible browser sat unused and unusable. The failure was latent — it
would have surfaced the first time anything passed `--browser chromium`.

### Fix

Installed revision 1237 using the *exact* `playwright-core` the server runs, rather than a fresh
`npx playwright install` that could resolve a different version:

```bash
node ~/.nvm/versions/node/v22.23.2/lib/node_modules/@playwright/mcp/node_modules/playwright-core/cli.js \
  install chromium chromium-headless-shell
```

Both are **Chrome for Testing 152.0.7977.8**. Verified the resolution afterwards:

```
chromium.executablePath() → ~/.cache/ms-playwright/chromium-1237/chrome-linux64/chrome
```

Final config — direct binary, pinned browser, devtools caps on:

```json
"playwright": {
  "command": "playwright-mcp",
  "args": ["--isolated", "--headless", "--browser", "chromium", "--caps", "devtools"]
}
```

## Three clients, one binary — the coupling worth knowing

This is the part that will bite later.

`playwright-mcp` is a **single global npm install** shared by all three clients, and each resolves
browsers out of the **same** `~/.cache/ms-playwright/`. They differ only in how they are invoked:

| | qwen-code (`~/.qwen/settings.json`) | Claude Code (`~/.claude.json`) | Zed (`~/.config/zed/settings.json`) |
|---|---|---|---|
| invocation | `playwright-mcp` shim | `playwright-mcp` shim | **absolute `node` + absolute `cli.js`** |
| args | `--browser chrome --executable-path /usr/bin/chromium-browser` | `--isolated --headless --browser chromium --caps devtools` | same as Claude Code |
| browser | snap Chromium 151.0.7922.108 | Chrome for Testing 152.0.7977.8 (rev 1237) | Chrome for Testing 152.0.7977.8 (rev 1237) |
| uses `ms-playwright` cache | **no** | yes | yes |

**Consequence:** upgrading the global `@playwright/mcp` changes the required browser revision for
*all three* clients at once, and silently breaks whichever ones use the bundled cache until
`playwright install` is re-run. qwen-code keeps working, because an explicit `--executable-path`
bypasses the cache entirely. That asymmetry is exactly how the 1234/1237 mismatch went unnoticed.

Zed is additionally coupled to the **nvm node version in its path strings**. `v22.23.2` is written
out in full, six times. An `nvm install` that moves the default node silently breaks every Zed
context server at once, with no fallback — see the PATH section below for why the shim could not be
used instead.

If the clients ever need to move independently, the fix is to stop sharing the global install —
pin each to its own `npx -y @playwright/mcp@<version>`, accepting the extra process per launch.

## Why three servers and not one

Checked before adding a second and third server, because tool count is a real cost here.

| | drives the browser | inspects runtime | breakpoints / stepping |
|---|---|---|---|
| `@playwright/mcp` | best-in-class | partial | no |
| `chrome-devtools-mcp` | adequate | best-in-class | no |
| `@debugmcp/mcp-debugger` | no | no | yes |

**Playwright's `--caps devtools` does not remove the need for the other two.** It adds
`browser_annotate`, `browser_highlight` / `browser_hide_highlight`, `browser_start_tracing` /
`browser_stop_tracing`, `browser_start_video` / `browser_stop_video`, and `browser_resume`. That
last one takes a `location` like `example.spec.ts:42` — it steps through **the Playwright test
script**, not the page's JavaScript. Useful; not a debugger.

Neither Playwright nor chrome-devtools-mcp sets breakpoints in application code. That capability
only exists in the third server.

## Measurements

Same method as the qwen-code section: tool lists pulled from each live server over stdio JSON-RPC;
CPU sampled from `/proc/<pid>/stat` over a 15 s window after a 5 s settle, **not** `ps %cpu`
(which reports a lifetime average dominated by startup).

### Tool counts

| server | tools | baseline without opt-in flags | delta |
|---|---|---|---|
| playwright | **35** | 24 | +11 (`--caps devtools`) |
| chrome-devtools | **40** | 29 | +11 (`--memoryDebugging`) |
| js-debugger | **21** | — | — |
| **total** | **96** | | |

The 24-tool baseline **independently reproduces** the figure in the README's qwen-code section,
measured six days earlier against a different client. Good cross-check on both numbers.

Note that both opt-in flags cost exactly 11 tools. `--caps devtools` was a deliberate choice;
`--memoryDebugging` likewise. Dropping both returns the stack to 74 tools.

### Startup and idle

n=3, median. Handshake is `initialize` → response; `tools/list` is measured separately after
`notifications/initialized`.

| server | `initialize` | `tools/list` | idle RSS | idle CPU |
|---|---|---|---|---|
| playwright | 237 ms | 5 ms | 110 MB | 0.80 % |
| chrome-devtools | 323 ms | 3 ms | 139 MB | 0.93 % |
| js-debugger | 182 ms | 4 ms | 94 MB | **0.00 %** |
| **total** | | | **343 MB** | ~1.7 % |

Playwright's 110 MB idle RSS reproduces the 109 MB in the README's qwen-code measurement.

`tools/list` is now single-digit milliseconds against the ~380 ms recorded on 2026-08-12. That is
a methodology difference, not a regression: the earlier figure timed the call from a cold client
where it was serialised behind server warm-up. Here the server has already completed `initialize`,
so the list is served from memory.

**No browser runs at idle** — all three launch lazily on first use. The 343 MB is the servers
alone.

### The memory caveat still applies

The README's warning holds and is the reason to watch this: this box runs **~54 GB of 60 used with
the model resident, ~6 GB available**, and `image-gen.md` is already blocked on exactly that.
343 MB of idle MCP servers is ~6 % of that headroom before a single browser starts. Chromium on
first `browser_navigate` is on top of it, and is **still unmeasured under load** — same open item
as on 2026-08-12, now with three servers resident instead of one.

Both browser servers run `--isolated`, which keeps the profile in RAM rather than on disk. That is
the cheaper choice for disk and the *more* expensive one for memory. Worth revisiting if launches
start failing.

## Zed — where the prompt cost actually shows up

Added 2026-08-14 to `~/.config/zed/settings.json`. The Zed in use is **the local fork build**, not a
release: `~/.local/zed.app` reports `Zed dev 1.17.0 4155aed35978c5`, which is the HEAD of
`prompt-fixes` in `~/code/zed` — the branch `zed-sampling.md` documents. So the settings schema
below was read out of that source tree rather than from published docs, and is authoritative for
this box only.

### The measurement that decided the design

**Zed sends full JSON tool schemas.** This is the whole story. qwen-code and Claude Code both
*defer* MCP tools — the schemas stay out of the declaration list and only a truncated name +
first-line description is advertised, which is why the README prices 24 Playwright tools at 632
tokens. Zed has no such mechanism: every enabled tool's complete JSON schema goes into the request.

Tool lists pulled from each live server over stdio JSON-RPC, serialised exactly as sent, and
tokenized against the running llama-server's `/tokenize` — the same instrument the README uses:

| server | tools | schema chars | **real tokens** |
|---|---|---|---|
| playwright | 35 | 25,942 | **6,454** |
| chrome-devtools | 40 | 33,620 | **8,351** |
| js-debugger | 21 | 11,586 | **2,821** |
| **all three** | **96** | **71,148** | **17,626** |

At 4.04 chars/token. Against the ~41.6k startup prompt this project exists to shrink:

| | |
|---|---|
| share of the startup prompt | **~42%** |
| prefill at the ~357 tok/s ceiling | **~49 s** |
| vs. Playwright's cost in qwen-code | 632 tokens → **10× more per tool set** |

For scale: removing computer use from qwen-code was worth 1,363 tokens and is recorded as a win.
Enabling all three of these globally in Zed would cost **thirteen times** what that win saved. It
would be the largest single prompt regression this project has measured.

### So: profiles, not global enablement

`default_profile` stays `minimal`, which costs nothing. The tools are paid for only on switching:

| profile | servers | tokens | share |
|---|---|---|---|
| `minimal` (default) | none | 0 | — |
| `browser` | playwright only | 6,454 | ~15% |
| `browser-debug` | all three | 17,626 | ~42% |

`browser` is the common case — drive, click, fill, snapshot, trace, video. `browser-debug` is for
when runtime diagnosis or real breakpoints are actually needed. Splitting them is the difference
between paying 15% and 42% on every turn of a session.

### Trap 1 — PATH, and why the shim could not be used

Zed's context servers are spawned via `command.envs(binary.env.unwrap_or_default())`
(`crates/context_server/src/transport/stdio_transport.rs`), which *adds* to Zed's inherited
environment rather than replacing it. So what matters is what Zed itself inherits.

A desktop-launched Zed inherits the **systemd user environment**, and that PATH does not contain
`~/.nvm/versions/node/v22.23.2/bin`. All three servers are `#!/usr/bin/env node` scripts, so this
breaks twice over: the shim name does not resolve, and even an absolute path to the shim would fail
because `node` is not on the PATH for the shebang to find.

Confirmed, not assumed:

```
$ env -i HOME=/home/jstormes PATH="$SYSTEMD_USER_PATH" playwright-mcp --version
env: 'playwright-mcp': No such file or directory
```

**Fix: invoke absolute `node` with the absolute script path**, removing PATH from the picture
entirely. Verified by handshaking all three servers under `env -i` with only the systemd user PATH
set — all three returned `serverInfo`.

The cost of this fix is the nvm version pin described in the coupling section above. A PATH entry in
`env` would have been the alternative; absolute paths were chosen because they also survive Zed
being launched from a terminal that *has* sourced nvm, giving one behaviour instead of two.

### Trap 2 — `minimal` gates context servers, and empty presets enable nothing

Two separate gotchas, the second of which produces a config that looks right and does nothing.

**First:** the shipped `minimal` profile sets `"enable_all_context_servers": false` (`write` sets it
true; `ask` has the line commented out). Since `minimal` was already the default here, no MCP tool
would ever have appeared regardless of how the servers were configured.

**Second:** enablement is resolved **per tool name**, not per server
(`crates/agent_settings/src/agent_profile.rs`):

```rust
pub fn is_context_server_tool_enabled(&self, server_id: &str, tool_name: &str) -> bool {
    self.context_servers
        .get(server_id)
        .and_then(|preset| preset.tools.get(tool_name).copied())
        .unwrap_or(self.enable_all_context_servers)
}
```

So a preset of `"playwright": {}` alongside `enable_all_context_servers: false` misses on every
lookup and falls through to `false` — **a Browser profile with zero browser tools**, silently. The
first draft of this config had exactly that bug. The `browser` profile therefore lists all 35
Playwright tool names explicitly as `true`; `browser-debug` takes the other route and sets
`enable_all_context_servers: true`.

### Config shape

`context_servers` lives at the **top level** of `settings.json` — it is part of
`ProjectSettingsContent`, which merges into user settings. `ContextServerSettingsContent` is an
**untagged** enum, so the variant is chosen by which keys are present: `command` selects Stdio,
`url` selects Http. Within Stdio, `ContextServerCommand` renames `path` to `command`, and takes
`args`, `env`, and `timeout`.

```json
"context_servers": {
  "playwright": {
    "command": "/home/jstormes/.nvm/versions/node/v22.23.2/bin/node",
    "args": ["…/@playwright/mcp/cli.js", "--isolated", "--headless",
             "--browser", "chromium", "--caps", "devtools"]
  }
}
```

`chrome-devtools` additionally carries `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1` in `env` and
`--no-performance-crux` in `args`, matching the Claude Code config.

### What is verified, and what is not

**Verified:** the file parses as JSONC; all three servers complete an MCP handshake under a
simulated desktop PATH; the profile schema matches the fork's Rust structs; the token figures come
from the real tokenizer.

**Not verified:** no agent turn has actually been run in Zed against these tools. The 17,626 figure
is the schema cost as sent, not an observed end-to-end prompt diff — Zed may add per-tool framing on
top. Treat it as a floor.

## Decisions made, and why

**Disabled Google's telemetry on chrome-devtools-mcp.** It defaults to *on*. Two separate flows:
`--usageStatistics` (default `true`) sends usage data to Google, and `--performanceCrux` (default
`true`) sends **URLs from performance traces** to the CrUX API. Set via the documented env var,
which the `--help` states also covers the case where `CI` is set:

```json
"env": { "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS": "1" }
```

On a project whose whole premise is a local model, shipping traced URLs to a third party by default
is worth an explicit opt-out.

**`--performanceCrux` closed 2026-08-14**, in both clients. It is a separate flag from the usage
statistics and needed its own opt-out. Both spellings work — `--no-performance-crux` (kebab, what
the server's own startup banner suggests) and `--performanceCrux=false` (camel, what `--help`
prints). The kebab form is used in both configs. Verification is direct rather than inferred: the
banner drops its CrUX line once the flag is set.

**Enabled `--memoryDebugging`.** The 12 heap-snapshot tools are opt-in, so the default footprint is
smaller than the raw tool list suggests. Turned on because leak-hunting is a main reason to carry
this server at all. Costs 11 tools; one flag to reverse.

**Both new servers run `--headless`,** matching the existing convention. For chrome-devtools
specifically this is arguable — seeing the page is much of the point when debugging interactively,
and the server's own default is headed. Drop the flag if that becomes annoying.

**Switched all three from `npx -y` to direct global binaries.** The old form spawned three
processes per server — `npm exec` → `sh -c` → `node` — visible in `ps` as three entries per
running client. Direct binaries spawn one. The trade is that version is now pinned by the global
install rather than by the config string, so `npm update -g` will move all three. See the coupling
section.

## Ruled out — do not re-evaluate without new information

**`microsoft/DebugMCP`** (v2.3.0, ~466 stars, 9 languages) is the better-backed debugger and was
rejected on a hard constraint, not on quality: it is a **VS Code extension**. It requires VS Code
running with the workspace open, and exposes MCP over streamable HTTP at `localhost:3001`. That
does not fit a CLI-and-Zed workflow. Revisit only if the editor situation changes.

**`johngrimes/mcp-js-debugger`** — CDP-based, attaches to Node and Chrome, so functionally on
target. **2 stars, 20 commits.** Not a dependency worth taking.

**One server instead of three** — ruled out above; `--caps devtools` does not cover breakpoints or
heap analysis.

## Honest state of the debugger half

`@debugmcp/mcp-debugger` is standalone and headless, which is why it was chosen — it needs no
editor and runs anywhere Node runs. It is also a **~153-star community project**, and it is the
strongest standalone option available. There is no mature, official, editor-independent JavaScript
breakpoint MCP. That is the state of the ecosystem as of 2026-08-14, not a gap in the search.

It reports **8 language adapters bundled**, verified by calling `list_supported_languages` on the
live server:

```
javascript (js-debug), python (debugpy), ruby (rdbg), go (Delve),
rust (CodeLLDB), java (JDI bridge), dotnet (netcoredbg), mock
```

JavaScript/TypeScript uses `js-debug` — the same adapter VS Code ships — so source maps and
attach-to-running-process come along. Covers both JS shapes on this box: `~/code/qwen-code`
(Node/TS, ESM) and `~/code/tetris` (browser, vanilla ES modules). The Rust adapter is an unplanned
bonus given `~/code/llama.cpp` and `cache-test-project`.

## Deleted — ~680 MB reclaimed

| | |
|---|---|
| `~/.cache/ms-playwright/chromium-1234` | 389 MB — wrong revision, unusable |
| `~/.cache/ms-playwright/chromium_headless_shell-1234` | 262 MB — same |
| `~/.cache/ms-playwright/.links` | stale pointer to an npx `playwright-core` **1.62.1** |
| `~/.cache/ms-playwright/b/` | empty |
| `~/.npm/_npx/9833c18b2d85bc59` | duplicate `@playwright/mcp` (npx cache copy) |
| `~/.npm/_npx/e41f203b7505f1fb` | orphaned `playwright-core` 1.62.1 |

`~/.cache/ms-playwright` 1.3 G → **655 MB**; `~/.npm/_npx` 43 MB → **5.8 MB**.

**This did not affect qwen-code.** Its Playwright MCP points at `/usr/bin/chromium-browser` via
explicit `--executable-path` and never reads the `ms-playwright` cache — checked before deleting.

`~/.claude.json` was backed up to `~/.claude.json.bak-<epoch>` first. Config edits went through
`claude mcp add` / `claude mcp remove` rather than hand-editing the file, because two Claude Code
sessions were live and either could have rewritten it from memory on exit.

## Open / unmeasured

- **Chromium RSS under load on this box.** Carried over from 2026-08-12 and now more pressing —
  three idle servers hold 343 MB before any browser starts, against ~6 GB free.
- **Prompt cost in Claude Code.** The qwen-code section prices its MCP tools in real tokens against
  the local server's `/tokenize`, and the Zed section above now does the same. No equivalent figure
  is recorded for Claude Code — its deferred tool mechanism differs from both, and no measurement
  was taken. The 96-tool count is *not* a token count and should not be presented as one. Note the
  Zed figure does **not** transfer: it is the full-schema cost, which is the thing deferral avoids.
- **No agent turn has been run in Zed** against these tools. The 17,626-token figure is schema cost
  as serialised, not an observed prompt diff — a floor, not a measurement of the real prompt.
- **The nvm version is pinned into the Zed config** as a literal path, six times. Nothing warns if
  `nvm install` moves the default node; every context server breaks at once.
- ~~`--performanceCrux` is still on~~ — **closed 2026-08-14**, see Decisions.
- **Whether the ~340 ms handshakes land on the launch critical path**, now ×3 servers.
- **Sandbox.** Chrome launches with `--no-sandbox` — stock Playwright behaviour
  (`chromiumSandbox` defaults false), not a local misconfiguration. Unprivileged user namespaces
  are available here (`kernel.unprivileged_userns_clone = 1`), so `--sandbox` is a live option and
  has not been tested.
