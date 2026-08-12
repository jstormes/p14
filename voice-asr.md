# p14 — local voice dictation for Qwen Code

Investigation date: **2026-08-06**
Host: p14 (ThinkPad P14s Gen 6 AMD, Radeon 890M / gfx1150, 60 GB, GTT 49152 MiB)
Goal: run speech-to-text locally and wire it into Qwen Code's `/voice` dictation.

Companion to [`README.md`](README.md) (llama.cpp throughput investigation).

---

## Outcome in one line

**Two working local ASR stacks were built. Neither is wired into Qwen Code yet** — one is
API-incompatible by design, the other is compatible but emits a marker prefix the client
does not strip. The remaining work is a ~20-line fixup, decision pending.

---

## What Qwen Code will actually accept

This is the constraint everything else follows from. Qwen Code **v0.21.7** does not accept
arbitrary OpenAI-compatible transcription endpoints. `transcribeVoiceAudio` dispatches on a
hardcoded model-id allowlist (`chunks/chunk-AE77C5ZU.js`):

```js
const transport = resolveVoiceTransport(voiceConfig.model);
switch (transport) {
  case "qwen-asr-chat":            return transcribeViaQwenAsr(...)
  case "qwen-asr-realtime":
  case "dashscope-task-realtime":  throw ... "requires streaming transcription"
  case "unsupported": default:     throw ... "is not a supported transcription model"
}
```

`resolveVoiceTransport` (`chunks/chunk-55LYDVPU.js`) matches only:

| id pattern | transport | usable here? |
|---|---|---|
| `qwen3-asr-flash` (optionally dated) | `qwen-asr-chat` | **yes** — plain POST |
| `qwen3-asr-flash-realtime*` | `qwen-asr-realtime` | no — throws in this path |
| `(fun-asr\|paraformer).*realtime` | `dashscope-task-realtime` | no — DashScope WebSocket protocol |

Anything else hits `default` and throws. **This is a code path, not a setting** — no
configuration reaches it.

`qwen-asr-chat` does **not** use `/v1/audio/transcriptions`. It POSTs to
**`{baseUrl}/chat/completions`** with an OpenAI multimodal message carrying
`input_audio` (base64). The reply is read as:

```js
const content = json.choices?.[0]?.message?.content;
const text = content.trim();     // <-- trim only, no marker stripping
```

### Other gates checked (all pass for loopback)

- `isTranscribableVoiceModel`: needs `authType === "openai"`, a non-empty `baseUrl`,
  and `imageOnly !== true`.
- HTTPS is **not** required for loopback. `isLoopbackHost` accepts exactly
  `localhost`, `127.0.0.1`, `::1`; the "must use an https baseUrl" branch is skipped
  when `isLocalhost`. Other private-network addresses (192.168.x, 10.x) are rejected.
- `general.voice.enabled` must be `true` (default `false`).

> ⚠ Unrelated but recorded for the image-generation work: `imageModel` **does** demand an
> **HTTPS** `baseUrl` plus `imageOnly: true` and `envKey`. A plain `http://127.0.0.1`
> endpoint will not satisfy it. Voice and image differ here — do not assume symmetry.

---

## Stack A — whisper.cpp (fast, but Qwen Code cannot use it)

Built from source, **v1.9.2**, `-DGGML_VULKAN=ON`. Installed to `/opt/whisper/bin`,
running as user unit `whisper.service` on `127.0.0.1:8081`.

| | |
|---|---|
| Model | `ggml-large-v3-turbo-q8_0.bin` (874 MB) in `/models` |
| Backend | Vulkan confirmed — `using Vulkan0 backend`, `KHR_coopmat` matrix cores |
| Speed | **~10× realtime** — 1.1 s for an 11 s clip |
| Endpoint | `/v1/audio/transcriptions` via `--inference-path` |
| Formats | WAV and compressed (WebM/Opus verified) via `--convert` + ffmpeg |

Build deps installed for this: `build-essential cmake glslc libvulkan-dev vulkan-tools
spirv-headers glslang-tools spirv-tools ffmpeg`. The first cmake run fails without
`spirv-headers` + `glslang-tools`.

> ⚠ **`whisper-server` writes each upload to a RELATIVE path** (`./whisper-server-*.wav`)
> before handing it to ffmpeg. With `WorkingDirectory=/opt/whisper` (root-owned) every
> request fails with `{"error":"FFmpeg conversion failed."}` — including plain WAV, since
> `--convert` routes everything through that temp file. The unit now uses
> `RuntimeDirectory=whisper` + `WorkingDirectory=%t/whisper`. **If transcription starts
> failing with an ffmpeg error, check the working directory is writable first.**

This stack is genuinely useful for any OpenAI-compatible client. It is simply not reachable
from Qwen Code, because `whisper-1` is not on the allowlist above.

---

## Stack B — Qwen3-ASR on the existing llama.cpp (API-compatible)

**No shim needed for transport.** The toolbox `libmtmd` already carries the `qwen3a` audio
projector:

```bash
strings /opt/llama/strix-toolbox/vulkan/bin/libmtmd.so.0.0.458 | grep -E '^(qwen3a|voxtral|ultravox)$'
# qwen3a  ultravox  voxtral
```

Models (official `ggml-org` GGUFs, both sha256-verified) in `/models`:

| file | bytes | sha256 (prefix) |
|---|---|---|
| `Qwen3-ASR-1.7B-Q8_0.gguf` | 2165034944 | `58e22d0532d4eaca` |
| `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf` | 355709344 | `46c1d533af3f354c` |

The mmproj declares `clip.audio.projector_type = qwen3a`, matching the build.

Launched manually for the test (**not yet a service**):

```bash
LD_LIBRARY_PATH=/opt/llama/strix-toolbox/vulkan/bin \
/opt/llama/strix-toolbox/vulkan/bin/llama-server \
  -m /models/Qwen3-ASR-1.7B-Q8_0.gguf \
  --mmproj /models/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf \
  -a qwen3-asr-flash \
  -ngl 999 -c 8192 --jinja \
  --host 127.0.0.1 --port 8082 -dev Vulkan0
```

Sending the exact `input_audio` shape Qwen Code produces returned a correct transcript in
**2 s**. Adds ~2.5 GB of GTT on top of `llama.service` + `whisper.service`.

> Note: launched via the raw binary here, **not** the toolbox wrapper. Per `README.md` §2
> that costs ~8% — irrelevant for a 1.7 B model, but use the wrapper if this becomes a
> permanent unit.

### The blocker

Qwen3-ASR always prefixes its output with a language tag and an `<asr_text>` marker
(a real token in the vocab, id present in `tokenizer.ggml.tokens`). Format is stable
across inputs, sample rates and clip lengths:

```
'language English<asr_text>And so, my fellow Americans, ask not what your country can do for you...'
'language English<asr_text>And so, my fellow Americans.'
```

llama.cpp has no ASR-specific output parser, and Qwen Code only `.trim()`s the content.
**Left as-is, dictation inserts `language English<asr_text>` into the prompt.** On the real
DashScope `qwen3-asr-flash` endpoint this stripping is the service's job.

Everything after the last `<asr_text>` is the clean transcript. Two candidate fixes:

| option | trade-off |
|---|---|
| Small loopback proxy that strips the prefix and forwards to 8082 | keeps Qwen Code stock; one more process |
| Patch the bundled JS in `node_modules/@qwen-code/qwen-code` | no extra process; **lost on every `npm update`** |

**Neither is implemented.** `voiceModel` is deliberately **not set** in
`~/.qwen/settings.json`, because every value would throw or inject junk.

---

## Download gotcha — cost the most time here

The HuggingFace **xet CDN truncates long transfers, and `curl` exits 0 on the short file.**
Three separate attempts produced 1434–1637 MB of a 2165 MB file, each reporting success.
`curl -C -` made it worse: the signed CDN URL ignores `Range` and returns the full body,
which curl appends, yielding a 2604 MB corrupt file.

**Use `wget -c` and always verify.** Authoritative size and checksum come from the HF API
(`x-linked-size` / `x-linked-etag`, or `/api/models/<repo>/tree/main` → `lfs.oid`):

```bash
wget -c -O out.gguf "https://huggingface.co/<repo>/resolve/main/<file>"
sha256sum out.gguf     # compare against lfs.oid from the API
```

A GGUF header parses fine on a truncated file — `magic=GGUF` proves nothing. Check bytes.

---

## Current state

As left at the end of the session (2026-08-06) — **both ASR stacks are built and verified
but deliberately not running**, pending the prefix-strip decision below:

| service | port | state |
|---|---|---|
| `llama.service` (Qwen3.6-35B-A3B) | 8080 | user unit, **active**, enabled at login |
| `whisper.service` (large-v3-turbo) | 8081 | user unit, **stopped and disabled** |
| Qwen3-ASR-1.7B | 8082 | **no unit** — manual launch only (command above) |

Nothing was deleted: `/opt/whisper/bin`, `whisper.service`, and all models remain on disk.

```bash
systemctl --user enable --now whisper.service   # bring stack A back
```

Both units are `WantedBy=graphical-session.target`, not `default.target` — GPU access comes
from the logind ACL granted to the active seat user, not group membership, so they must not
start before login. Same reasoning as `llama.service`.

`~/.qwen/settings.json` is unchanged for voice: no `voiceModel`, `general.voice.enabled`
still default `false`.

## Next steps

1. Decide prefix-strip approach (proxy vs patch).
2. Promote the ASR server to a user unit, using the toolbox wrapper.
3. Set `voiceModel: "qwen3-asr-flash"` + a `modelProviders.openai` entry with
   `baseUrl: "http://127.0.0.1:8082/v1"`, and `general.voice.enabled: true`.
4. Decide whether `whisper.service` stays. It is faster and more accurate than the 1.7 B
   ASR model, but unreachable from Qwen Code — keep only if another client will use it.
