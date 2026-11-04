# ollarc-intel

**The current upstream [Ollama](https://github.com/ollama/ollama), accelerated on Intel GPUs through the llama.cpp SYCL backend (oneAPI / Level Zero).**

Ollama officially supports NVIDIA, AMD and (slower) Vulkan. `ipex-llm` is no longer developed, Vulkan leaves a lot of performance on Intel iGPUs unused, and OpenVINO needs a separate model workflow. ollarc-intel takes the current Ollama release unchanged, adds a small patch set for a SYCL GPU backend, and rebuilds automatically whenever Ollama ships a new version.

- ✅ normal Ollama: `ollama pull`, `ollama run`, the API, Open WebUI. Models come straight from the Ollama registry, so you don't need to copy GGUF files by hand
- ✅ Intel Arc / Xe iGPUs: Meteor Lake, **Arrow Lake** (Core Ultra 200H, e.g. 285H in the ASUS NUC 15 Pro / Pro+), Lunar Lake, Arc A-/B-series
- ✅ newest toolchain: oneAPI 2026.2, the llama.cpp build that Ollama pins (newer ones selectable)
- ✅ follows upstream: a daily CI build of every new Ollama release

> Running on Proxmox VE? See the [Proxmox guide](docs/proxmox.md) (LXC recommended).

## Status

Tested on an ASUS NUC with Core Ultra 9 285H (Arc 140T iGPU), Proxmox VE 9 LXC, Ollama v0.40.14:

| Model | Result | Decode |
|---|---|---|
| `llama3.2:3b` | ✅ 100 % GPU, correct | 22.7 tok/s |
| `qwen3.8:27b` (Q4) | ✅ 100 % GPU (66/66 layers) | dense 27B, slow on any iGPU |
| `gpt-oss:20b` | ✅ correct with the JIT image | |

Problems found on the way, their causes and fixes are in
[docs/known-issues.md](docs/known-issues.md). If something does not work, start with
[docs/diagnostics.md](docs/diagnostics.md).

## Quick start (Docker + Open WebUI)

```bash
git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(getent group render | cut -d: -f3)" > .env
docker compose up -d
docker compose exec ollama ollama pull llama3.2:3b
```

Open WebUI: `http://<host>:3000` · Ollama API: `http://<host>:11434`

Check that the GPU is used:

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
| `:latest-arl-h-beta` | same as `latest-arl-h` | kept for existing setups |

JIT images compile the GPU kernels once when a model is loaded; AOT images ship them
precompiled, which only shortens that first load. Inference speed is the same.

> **AOT and models above 4 GB.** Upstream llama.cpp builds AOT kernels without support
> for GPU buffers larger than 4 GB, so every model above ~4 GB (gpt-oss, Qwen 27B, …)
> produced garbage such as `GGGG…` with the first `latest-arl-h` images.
> [`patches/llama.cpp/900-sycl-aot-4gb-buffers.patch`](patches/llama.cpp/900-sycl-aot-4gb-buffers.patch)
> fixes the build (verified with gpt-oss:20b on an Arc 140T). If you still get `GGGG…`,
> run `docker compose pull`.
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
```

## Benchmark

```bash
./scripts/bench.sh llama3.2:3b qwen3.8:latest
```

The script prints prefill and decode tokens/s, so you can compare against Vulkan or OpenVINO on the same machine. Please post your results in an issue or discussion.

## Tuning

See [docs/tuning.md](docs/tuning.md). In short: `Q4_0` quants are the most optimized path on SYCL, MoE models (`gpt-oss`, `…-a3b`) are much faster on an iGPU than dense models of the same size, and thinking can be switched off per model in Open WebUI.

## Documentation

| Document | Content |
|---|---|
| [docs/proxmox.md](docs/proxmox.md) | Proxmox VE: LXC with `/dev/dri`, or returning an iGPU from VM passthrough |
| [docs/tuning.md](docs/tuning.md) | environment variables, model choice, context length |
| [docs/diagnostics.md](docs/diagnostics.md) | is the GPU used, benchmark, `test-backend-ops`, tensor bisection |
| [docs/known-issues.md](docs/known-issues.md) | everything found so far, with causes and fixes |
| [docs/upstream/](docs/upstream/) | reports prepared for upstream projects |

## Maintainer notes (CI)

- `.github/workflows/build.yml` runs daily. It builds the JIT image and the Arrow Lake-H AOT image for the newest upstream release and pushes them to GHCR. The JIT build fails if a SYCL / Level Zero library is unresolved in the image.
- First run: *Actions → build → Run workflow*. Afterwards set the package to **public** under *Packages → ollarc-intel → Package settings → Change visibility*.
- The repository must be **public** for unlimited free Actions minutes.

## License

MIT, same as Ollama. Not affiliated with Ollama or Intel.
