# ollarc-intel

[![Docker Pulls](https://img.shields.io/docker/pulls/dosperado74/ollarc-intel?logo=docker)](https://hub.docker.com/r/dosperado74/ollarc-intel)
[![Image size](https://img.shields.io/docker/image-size/dosperado74/ollarc-intel/latest?logo=docker)](https://hub.docker.com/r/dosperado74/ollarc-intel/tags)

**The current upstream [Ollama](https://github.com/ollama/ollama), accelerated on Intel GPUs through the llama.cpp SYCL backend (oneAPI / Level Zero).**

Ollama officially supports NVIDIA, AMD and (slower) Vulkan. `ipex-llm` is no longer developed, Vulkan leaves a lot of performance on Intel iGPUs unused, and OpenVINO needs a separate model workflow. ollarc-intel takes the current Ollama release unchanged, adds a small patch set for a SYCL GPU backend, and rebuilds automatically whenever Ollama ships a new version.

- ✅ normal Ollama: `ollama pull`, `ollama run`, the API, Open WebUI. Models come straight from the Ollama registry, so you don't need to copy GGUF files by hand
- ✅ made for Intel Arc / Xe iGPUs: Meteor Lake, **Arrow Lake** (Core Ultra 200H, e.g. 285H, 265H, 255H), Lunar Lake
- ✅ dedicated Arc cards work too: A770, A750, A580, A380, B580, B570, … ([docs/arc-dgpu.md](docs/arc-dgpu.md))
- ✅ newest toolchain: oneAPI 2026.2, the llama.cpp build that Ollama pins (newer ones selectable)
- ✅ follows upstream: a daily CI build of every new Ollama release

> [!IMPORTANT]
> **No Proxmox? Install the Intel GPU firmware on the host first.** Without it the iGPU
> cannot run compute work and Ollama silently falls back to the CPU.
>
> ```bash
> # Debian 13 (enable "non-free-firmware" in the apt sources first)
> sudo apt install firmware-intel-graphics && sudo update-initramfs -u -k all && sudo reboot
> # Debian 12: firmware-misc-nonfree instead · Ubuntu / Fedora / Proxmox VE: already included
> ```
>
> Runs directly on a Linux host (Debian, Ubuntu, Fedora, …) or in a Proxmox VE LXC, see
> [Quick start](#quick-start-docker--open-webui).

## Status

Tested on an ASUS NUC 14 Pro+ with Core Ultra 9 285H (Arc 140T iGPU), Proxmox VE 9 LXC.
Decode: Ollama v0.40.16 (values marked ¹: v0.40.14). Prefill: v0.40.14 with the prompt length given:

| Model | Result | Prefill | Decode |
|---|---|---|---|
| `llama3.2:3b` (Q4_K_M) | ✅ 100 % GPU, `latest-arl-h` | **1249 tok/s** (~800-token prompt) | **26.1 tok/s** |
| `gpt-oss:20b` (MXFP4) | ✅ 100 % GPU, `latest-arl-h` | 288 tok/s (~800-token prompt), **1106 tok/s** (6549-token prompt) | **14.0 tok/s** (empty context), 10.6 tok/s (6.5K context)¹ |
| `gemma4:e4b` | ✅ 100 % GPU, `latest-arl-h` (per-layer embeddings stay in RAM by design) | 361 tok/s (~800-token prompt) | **16.1 tok/s**¹ |
| [`gemma-4-26B-A4B-it-qat-q4_0`](https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf) (MoE, QAT Q4_0) | ✅ 100 % GPU, `latest-arl-h` | 184 tok/s (~800-token prompt) | **14.6 tok/s** (`gemma4:26b-qat` from the Ollama registry) |
| `qwen3.8:27b` (Q4, dense) | ✅ 100 % GPU (66/66 layers), `latest-arl-h` | 109 tok/s (~800-token prompt) | 3.2–5.9 tok/s¹ (depends on how well its MTP head predicts), 3.6 tok/s with v0.40.16 |

Measured in Open WebUI / `scripts/bench.sh` (decode with `./scripts/bench.sh --all`). MoE models like gpt-oss process long prompts much more
efficiently than short ones, because each expert gets a bigger batch. More results from other Intel
GPUs are very welcome: [share a benchmark](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml).

> [!NOTE]
> **UGREEN NASync iDX6011 Pro (AI NAS):** same Arc 140T iGPU (Core Ultra 7 255H), so it should run
> with `latest-arl-h`, but it is **not tested yet**. Details in [docs/devices.md](docs/devices.md).

Problems found on the way, their causes and fixes are in
[docs/known-issues.md](docs/known-issues.md). If something does not work, start with
[docs/diagnostics.md](docs/diagnostics.md).

## Quick start (Docker + Open WebUI)

### 1. Prepare the host

The container brings the whole Intel GPU user space. The host only needs a recent kernel
(Meteor/Lunar Lake ≥ 6.8, Arrow Lake ≥ 6.11) and the **Intel GPU firmware**. Without the
firmware the GPU cannot run compute work and Ollama falls back to the CPU.

| Host | What to do |
|---|---|
| **Debian 13** | enable `non-free-firmware`, `sudo apt install firmware-intel-graphics`, `sudo update-initramfs -u -k all`, reboot |
| **Debian 12** | same, with `firmware-misc-nonfree` |
| **Ubuntu / Fedora** | nothing, `linux-firmware` is installed by default |
| **Proxmox VE** | nothing on the host (`pve-firmware`), run it in an LXC: [Proxmox guide](docs/proxmox.md) |

Check: `ls /dev/dri` shows `renderD128`. Details and troubleshooting: [docs/host-setup.md](docs/host-setup.md).
Dedicated Arc card: also enable Resizable BAR, see [docs/arc-dgpu.md](docs/arc-dgpu.md).

### 2. Start Ollama + Open WebUI

```bash
curl -fsSL https://get.docker.com | sh            # if Docker is not installed yet
git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" > .env
docker compose up -d
docker compose exec ollama ollama pull llama3.2:3b
```

Open WebUI: `http://<host>:3000` · Ollama API: `http://<host>:11434`

On Arrow Lake-H (Core Ultra 200H, Arc 140T/130T) add `OLLARC_TAG=latest-arl-h` to `.env`
for precompiled kernels (faster first model load).

Dedicated Arc card: `OLLARC_TAG=latest-dg2` (A-series) or `latest-bmg` (B-series). If the CPU
also has an iGPU, restrict Ollama to the Arc card, see [docs/arc-dgpu.md](docs/arc-dgpu.md#3-cpu-with-an-igpu-use-only-the-arc-card).

### 3. Check that the GPU is used

```bash
docker compose logs ollama | grep -i "inference compute"   # -> library=SYCL ... Intel(R) Arc(TM) ...
docker compose exec ollama ollama ps                        # -> PROCESSOR 100% GPU
```

## Images

| Tag | Kernels | For |
|---|---|---|
| `ghcr.io/dosperado74/ollarc-intel:latest` | JIT (SPIR-V) | **recommended**, every supported Intel GPU |
| `:<ollama-version>` | JIT | pinned versions, e.g. `0.40.14` |
| `:latest-arl-h` | AOT `arl-h` + 4 GB fix | Arrow Lake-H (Core Ultra 200H, Arc 140T / 130T): faster first load |
| `:latest-dg2` | AOT `acm-g10,acm-g11` + 4 GB fix | dedicated Arc A-series (A770, A750, A580, A380, A310), not yet verified on hardware |
| `:latest-bmg` | AOT `bmg-g21` + 4 GB fix | dedicated Arc B-series (B580, B570, Arc Pro B50 / B60), not yet verified on hardware |

JIT images compile the GPU kernels once when a model is loaded; AOT images ship them
precompiled, which only shortens that first load. Inference speed is the same.
Every AOT tag also exists per version, e.g. `0.40.14-dg2`.

The same images are also on Docker Hub: [`dosperado74/ollarc-intel`](https://hub.docker.com/r/dosperado74/ollarc-intel)
with identical tags (`docker pull dosperado74/ollarc-intel:latest-arl-h`). In `docker-compose.yml`, set
`OLLARC_IMAGE=dosperado74/ollarc-intel` in `.env` to pull from there.

> **AOT and models above 4 GB.** Upstream llama.cpp builds AOT kernels without support
> for GPU buffers larger than 4 GB, so every model above ~4 GB (gpt-oss, Qwen 27B, …)
> produced garbage such as `GGGG…` with the first `latest-arl-h` images.
> [`patches/llama.cpp/900-sycl-aot-4gb-buffers.patch`](patches/llama.cpp/900-sycl-aot-4gb-buffers.patch)
> fixes the build (verified with gpt-oss:20b on an Arc 140T). If you still get `GGGG…`,
> run `docker compose pull`. The fix is merged upstream
> ([ggml-org/llama.cpp#31873](https://github.com/ggml-org/llama.cpp/pull/31873)); the patch is
> dropped once Ollama ships a llama.cpp that contains it.
> Details: [known-issues.md §3](docs/known-issues.md#3-models-above-4-gb-compute-garbage-with-aot-kernels).

## How it works

Ollama ≥ 0.40 runs inference through upstream `llama-server` and loads one ggml GPU backend module per GPU family (`lib/ollama/<backend>/libggml-*.so`). ollarc-intel adds a `sycl` backend:

| Patch | Content |
|---|---|
| [`0001-build-add-sycl-llama-server-backend`](patches/0001-build-add-sycl-llama-server-backend.patch) | CMake preset + superbuild target, which builds `libggml-sycl.so` with `icpx` |
| [`0002-discover-recognize-intel-sycl-devices`](patches/0002-discover-recognize-intel-sycl-devices.patch) | GPU discovery: library `SYCL`, iGPU admission, `ONEAPI_DEVICE_SELECTOR`, flash attention, preference over Vulkan |
| [`llama.cpp/900-sycl-aot-4gb-buffers`](patches/llama.cpp/900-sycl-aot-4gb-buffers.patch) | llama.cpp: >4 GB buffer support for AOT kernels (applied through Ollama's `llama/compat` mechanism) |

The image also fixes two problems of the oneAPI runtime on iGPUs: the missing
`libumf.so.1` linker path, and free memory reported via Level Zero Sysman, which made
llama-server put no layer on the iGPU. See [known-issues.md](docs/known-issues.md).

The patches are small on purpose so they keep applying to new Ollama releases. If an upstream change breaks them, the scheduled build opens an issue.

## Build it yourself

```bash
docker build -t ollarc-intel .                                             # current UPSTREAM_VERSION, JIT
docker build --build-arg OLLAMA_VERSION=v0.40.14 --build-arg LLAMA_CPP_VERSION=b12086 .
docker build --build-arg SYCL_DEVICE_ARCH=arl-h -t ollarc-intel:arl-h .   # AOT for Arrow Lake-H
docker build --build-arg SYCL_DEVICE_ARCH=acm-g10,acm-g11 -t ollarc-intel:dg2 .   # AOT for Arc A-series
docker build --build-arg SYCL_DEVICE_ARCH=bmg-g21 -t ollarc-intel:bmg .   # AOT for Arc B-series
```

## Benchmark

```bash
./scripts/bench.sh llama3.2:3b qwen3.8:latest
./scripts/bench.sh --all                       # every installed model
```

The script prints prefill and decode tokens/s, the time of the first request (model load, kernel JIT) and how much of the model sits on the GPU, so you can compare against Vulkan or OpenVINO on the same machine. To compare environment variables, `scripts/ab-env.sh` recreates the container once per variant, benchmarks it, checks the answers and restores your configuration afterwards, see [docs/diagnostics.md](docs/diagnostics.md#ab-testing-runtime-switches):

```bash
./scripts/ab-env.sh baseline baseline OLLAMA_FLASH_ATTENTION=1
```

Please share your results with the [benchmark form](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml): it asks for everything needed to compare GPUs.

## Tuning

See [docs/tuning.md](docs/tuning.md). In short: `Q4_0` quants are the most optimized path on SYCL, MoE models (`gpt-oss`, `…-a3b`) are much faster on an iGPU than dense models of the same size, and thinking can be switched off per model in Open WebUI. Some switches that other Intel GPU setups use (`SYCL_CACHE_PERSISTENT`, `UR_L0_USE_IMMEDIATE_COMMANDLISTS`) are [deliberately not used](docs/tuning.md#deliberately-not-used), with the reasons.

## What about the NPU?

The NPU (Intel AI Boost) in Meteor / Arrow / Lunar Lake is **not used**, and that is on purpose:

- llama.cpp, and therefore Ollama, has no NPU backend. On Linux the NPU is only reachable through
  OpenVINO (kernel driver `intel_vpu`, `/dev/accel/accel0`), a separate stack with its own model format.
- For LLMs the Arc GPU is the stronger part: on Arrow Lake-H the NPU delivers about 13 TOPS, the
  Arc 140T about 77 TOPS. The "~100 platform TOPS" in spec sheets are CPU + GPU + NPU combined.
- Token generation is limited by memory bandwidth, and NPU and GPU share the same RAM, so the NPU
  could not generate tokens faster anyway.

The NPU's strength is power efficiency for small, always-on models (speech recognition, embeddings,
photo tagging), not chat-sized LLMs.

## Documentation

| Document | Content |
|---|---|
| [docs/host-setup.md](docs/host-setup.md) | plain Linux host without Proxmox: kernel, GPU firmware, Docker |
| [docs/arc-dgpu.md](docs/arc-dgpu.md) | dedicated Arc A-/B-series cards: kernel, Resizable BAR, images, iGPU + dGPU, VRAM |
| [docs/devices.md](docs/devices.md) | devices with the same GPU that are not tested yet (e.g. UGREEN NASync iDX6011 Pro) |
| [docs/proxmox.md](docs/proxmox.md) | Proxmox VE: LXC with `/dev/dri`, or returning an iGPU from VM passthrough |
| [docs/tuning.md](docs/tuning.md) | environment variables, model choice, context length |
| [docs/diagnostics.md](docs/diagnostics.md) | is the GPU used, benchmark, A/B testing runtime switches (`scripts/ab-env.sh`) |
| [docs/known-issues.md](docs/known-issues.md) | everything found so far, with causes and fixes |
| [docs/upstream/](docs/upstream/) | reports prepared for upstream projects |

## Maintainer notes (CI)

- `.github/workflows/build.yml` runs daily. It builds the JIT image and the AOT images (Arrow Lake-H, Arc A-series `dg2`, Arc B-series `bmg`) for the newest upstream release and pushes them to GHCR. The JIT build fails if a SYCL / Level Zero library is unresolved in the image.
- First run: *Actions → build → Run workflow*. Afterwards set the package to **public** under *Packages → ollarc-intel → Package settings → Change visibility*.
- The repository must be **public** for unlimited free Actions minutes.
- Docker Hub mirror (optional): add the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (Docker Hub personal access token). The `dockerhub` job then copies every GHCR tag 1:1 to [`docker.io/dosperado74/ollarc-intel`](https://hub.docker.com/r/dosperado74/ollarc-intel) (no second build) and fills in missing tags daily. With a *Read, Write & Delete* token it also publishes [docs/dockerhub.md](docs/dockerhub.md) as the Docker Hub overview. Without the secrets the job is skipped.

## License

MIT, same as Ollama. Not affiliated with Ollama or Intel.
