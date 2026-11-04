# ollarc-intel

**The current upstream [Ollama](https://github.com/ollama/ollama), accelerated on Intel GPUs through the llama.cpp SYCL backend (oneAPI / Level Zero).**

Ollama officially supports NVIDIA, AMD and (slower) Vulkan. `ipex-llm` is no longer developed, Vulkan leaves a lot of performance on Intel iGPUs unused, and OpenVINO needs a separate model workflow. ollarc-intel takes the current Ollama release unchanged, adds a small patch set for a SYCL GPU backend, and rebuilds automatically whenever Ollama ships a new version.

- ✅ normal Ollama: `ollama pull`, `ollama run`, the API, Open WebUI. Models come straight from the Ollama registry, so you don't need to copy GGUF files by hand
- ✅ Intel Arc / Xe iGPUs: Meteor Lake, **Arrow Lake** (Core Ultra 200H, e.g. 285H in the ASUS NUC 15 Pro / Pro+), Lunar Lake, Arc A-/B-series
- ✅ newest toolchain: oneAPI 2026.2, the llama.cpp build that Ollama pins (newer ones selectable)
- ✅ follows upstream: a daily CI build of every new Ollama release

> Running on Proxmox VE? See the [Proxmox guide](docs/proxmox.md) (LXC recommended).

## Quick start (Docker + Open WebUI)

```bash
git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(getent group render | cut -d: -f3)" > .env
docker compose up -d
docker compose exec ollama ollama pull qwen3:8b
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
| `ghcr.io/dosperado74/ollarc-intel:latest` | JIT (SPIR-V) | every supported Intel GPU |
| `:<ollama-version>` | JIT | pinned versions, e.g. `0.40.14` |

> **No ahead-of-time (AOT) images.** llama.cpp builds AOT SYCL kernels without
> support for GPU buffers larger than 4 GB, so every model above ~4 GB (gpt-oss,
> Qwen 27B, …) produces garbage such as `GGGG…`. The former `latest-arl-h` tag now
> points to the JIT image. The first load of a model compiles its kernels once.

## How it works

Ollama ≥ 0.40 runs inference through upstream `llama-server` and loads one ggml GPU backend module per GPU family (`lib/ollama/<backend>/libggml-*.so`). ollarc-intel adds a `sycl` backend:

| Patch | Content |
|---|---|
| [`0001-build-add-sycl-llama-server-backend`](patches/0001-build-add-sycl-llama-server-backend.patch) | CMake preset + superbuild target, which builds `libggml-sycl.so` with `icpx` |
| [`0002-discover-recognize-intel-sycl-devices`](patches/0002-discover-recognize-intel-sycl-devices.patch) | GPU discovery: library `SYCL`, iGPU admission, `ONEAPI_DEVICE_SELECTOR`, flash attention, preference over Vulkan |

The patches are small on purpose so they keep applying to new Ollama releases. If an upstream change breaks them, the scheduled build opens an issue.

## Build it yourself

```bash
docker build -t ollarc-intel .                                             # current UPSTREAM_VERSION, JIT
docker build --build-arg OLLAMA_VERSION=v0.40.14 --build-arg LLAMA_CPP_VERSION=b12086 .
```

## Benchmark

```bash
./scripts/bench.sh llama3.2:3b qwen3:8b
```

The script prints prefill and decode tokens/s, so you can compare against Vulkan or OpenVINO on the same machine. Please post your results in an issue or discussion.

## Tuning

See [docs/tuning.md](docs/tuning.md). In short: `Q4_0` quants are the most optimized path on SYCL, and `OLLAMA_FLASH_ATTENTION=1` usually helps. If a model outputs garbage, use `GGML_SYCL_DYNAMIC_PRECISION=BF16`.

## Maintainer notes (CI)

- `.github/workflows/build.yml` runs daily. It builds both image flavors for the newest upstream release and pushes them to GHCR.
- First run: *Actions → build → Run workflow*. Afterwards set the package to **public** under *Packages → ollarc-intel → Package settings → Change visibility*.
- The repository must be **public** for unlimited free Actions minutes.

## License

MIT, same as Ollama. Not affiliated with Ollama or Intel.
