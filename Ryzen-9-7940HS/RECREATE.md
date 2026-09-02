# Recreating llm3 from scratch

Step-by-step to rebuild the llm3 inference node on an ALLOY9-7940HS (or any
Ryzen 9 7940HS / Radeon 780M box with 64 GB DDR5-5600). File references point at
[assets/](assets/).

## 0. Hardware prep

- 2 × 32 GB DDR5-5600 SODIMM (dual-channel is mandatory — the whole box is
  bandwidth-bound).
- BIOS: leave the UMA/VRAM carve-out at minimum (~512 MB). Measured on this
  hardware class: carve-out size makes zero throughput difference; GTT does the
  real work.
- NVMe ≥ 256 GB (models take ~70 GB with the rollback quant).

## 1. OS install

Ubuntu Server 26.04 LTS, single ext4 root, OpenSSH. Hostname `llm3`, user
`jstormes`. Then:

```bash
sudo apt update && sudo apt full-upgrade
sudo apt install avahi-daemon   # fleet-proxy reaches the box as llm3.local
```

## 2. Kernel parameters (the single highest-value step)

Edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="amdgpu.gttsize=57344 ttm.pages_limit=14680064 ttm.page_pool_size=14680064 amd_iommu=off"
```

```bash
sudo update-grub && sudo reboot
```

- `amdgpu.gttsize=57344` = 56 GiB GTT out of 61 GiB usable (92%). The 35 GiB
  model + 256K q8_0 KV (~19.3 KiB/token ≈ 4.8 GiB) + compute buffers all live in GTT.
- `ttm.pages_limit` = `ttm.page_pool_size` = 57344 MiB × 1024² / 4096 = **14680064**
  (gttsize is deprecated in favor of pages_limit; set both, they must agree).
- `amd_iommu=off`: the model is GTT-resident, so every GPU access to system RAM
  otherwise pays IOMMU translation. Worth +19–26% prefill / +15% gen (P14s
  measurement). **Do not lose this flag on kernel/GRUB updates** — its removal
  once masqueraded as a 23% hardware regression.

Verify after reboot: `cat /proc/cmdline` and `sudo dmesg | grep "GTT memory"`
(expect `57344M of GTT memory ready`).

## 3. Graphics stack

```bash
sudo add-apt-repository ppa:kisak/kisak-mesa
sudo apt update && sudo apt full-upgrade        # mesa-vulkan-drivers 26.1.x
sudo apt install vulkan-tools
vulkaninfo --summary | grep -E "deviceName|driverInfo"   # expect RADV PHOENIX, Mesa 26.1.x kisak
```

llm3 currently runs Mesa 26.1.7 unheld. (The P16s pinned 26.1.5 with `apt-mark
hold` for byte-parity experiments; llm3 floats with the PPA.)

## 4. Build llama.cpp (Vulkan, b10173)

```bash
sudo apt install build-essential cmake git glslc libshaderc-dev libvulkan-dev
sudo mkdir -p /opt/llama && sudo chown $USER /opt/llama
git clone https://github.com/ggml-org/llama.cpp /opt/llama/llama.cpp-b10173
cd /opt/llama/llama.cpp-b10173
git checkout e9fa0781f          # = tag b10173, the production pin
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON
cmake --build build -j$(nproc)
```

Vulkan-only: rocBLAS has no `gfx1103` kernels, so ROCm does not work on this GPU
(and a `gfx1151` HSA override is a mistuned hack — measured worse than Vulkan on
the 16-CU part; never validated here). b10173 was adopted 2026-07-28 as
perf-neutral vs b9811, taken for stability.

## 5. Models

```bash
mkdir -p /mnt/data/models/Qwen3.6-35B-A3B-Q8   # plain dir on root fs — deliberate, no separate disk
```

Download into it (from unsloth's GGUF conversion of Qwen/Qwen3.6-35B-A3B):
- `Qwen3.6-35B-A3B-Q8_0.gguf` (35.2 GiB) — the MTP head is embedded; no draft file needed.
- `mmproj-BF16.gguf` (0.9 GiB) — vision projector; quant-independent (same file
  serves every quant of this conversion; fleet copies sha256 `c8e70234…af414`).

Optional rollback quant in `/mnt/data/models/Qwen3.6-35B-A3B-MTP/`:
`Qwen3.6-35B-A3B-UD-Q6-MTP_K_XL.gguf` (30.4 GiB). On 12 CUs Q8_0 is only +6%
prefill over Q6, but it's higher quality at the same ~22 t/s decode; Q6 buys
12 GiB of GTT headroom if that ever matters again.

## 6. systemd units

Copy from assets/ and enable:

```bash
sudo cp assets/cpu-performance.service assets/llama-qwen3.6-35b-q8.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service llama-qwen3.6-35b-q8.service
```

- `cpu-performance.service`: CPU governor `performance` + GPU DPM `high`, and
  (via its 10 s sleep + unit ordering) gates llama startup on GPU readiness.
  Note: DPM `high` vs `auto` measured a dead tie here (2026-09-02) — kept for
  the boot-gating, not for speed.
- `llama-qwen3.6-35b-q8.service`: the production server (flags documented in
  [README.md](README.md)). First start takes ~1–2 min (`--no-mmap` loads 35 GiB).

Verify: `curl -s localhost:8080/health` → `{"status":"ok"}`, and GTT residency via
`cat /sys/class/drm/card*/device/mem_info_gtt_used` (expect ~40+ GiB).

## 7. Optional: switchable-variant harness

For A/B-ing alternative builds (e.g. the strix-halo toolbox in
`/opt/llama/strix-toolbox`) without editing the production unit:

```bash
sudo cp assets/llama-launch assets/llama-variant /usr/local/bin/
sudo cp assets/llama-variant.service /etc/systemd/system/   # disabled by default; Conflicts= the prod unit
sudo cp -r assets/llama-variants /etc/
```

`llama-variant` (no args) lists variants; `llama-variant <name>` stops the
production unit, starts `llama-variant.service` with that build, and verifies
weights landed on the GPU. **Caveat:** `llama-launch` currently carries
`-np 2 -kvu` where production is `-np 1` without `-kvu` — reconcile before
trusting it as a control arm.

## 8. Monitoring niceties

btop 1.4.6 GPU monitoring needs manual symlinks (Ubuntu ships versioned .so only):

```bash
cd /usr/lib/x86_64-linux-gnu
sudo ln -s librocm_smi64.so.7 librocm_smi64.so
sudo ln -s libdrm_amdgpu.so.1 libdrm_amdgpu.so
```

## 9. Fleet integration (on cloud1, not on llm3)

The router at `llm.stormes.net` (cloud1 `/srv/llm`, `fleet_proxy.py` in the
`fleet-proxy` container, host port 18077) carries:

```python
{"name": "llm3-8080", "url": "http://llm3.local:8080"},
```

The model→backend map self-builds from each backend's `/v1/models` (30 s health
loop), so once llm3's server is healthy the alias `Qwen3.6-35B-A3B-Q8-780M`
appears on the public route automatically. Every fleet model caps at 262144
tokens per request at the proxy.

## 10. Verification benchmark

Sanity numbers for a fresh build (direct to `:8080`, see README for protocol):
~400 t/s prefill @3K prompt, ~380 @8K, ~23 t/s generation mean with 20–28
spread. If prefill lands ~20% low, check `amd_iommu=off` survived (step 2).
Generation benching on this box requires n≥10 interleaved runs — MTP acceptance
noise at temp 1.0 swings single runs by ±4 t/s.

## 11. Known gaps to consider fixing on a rebuild

- No hardware watchdog / netconsole despite 3 silent freezes (proposed in fleet
  notes 2026-08-27).
- `RADV_PERFTEST=nogttspill` in the unit is a measured no-op — drop it on a
  clean rebuild.
- Unit `Description` ("3x256K") and the launcher (`-np 2 -kvu`) disagree with
  the production flags (`-np 1`, no `-kvu`) — pick one truth.
