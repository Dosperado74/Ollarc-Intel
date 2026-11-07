# ollarc-intel

**The current upstream [Ollama](https://github.com/ollama/ollama), accelerated on Intel GPUs through the llama.cpp SYCL backend (oneAPI / Level Zero).**

Normal Ollama (`ollama pull`, `ollama run`, the API, Open WebUI), but with a SYCL GPU backend for
Intel Arc / Xe iGPUs (Meteor Lake, Arrow Lake, Lunar Lake) and dedicated Arc cards (A-series, B-series).
Rebuilt automatically for every new Ollama release.

Source, docs and issues: **https://github.com/Dosperado74/ollarc-intel**

> This page is generated from [`docs/dockerhub.md`](https://github.com/Dosperado74/ollarc-intel/blob/main/docs/dockerhub.md).
> The same images are also published as `ghcr.io/dosperado74/ollarc-intel`.

## Performance

ASUS NUC 14 Pro+, Core Ultra 9 285H (Arc 140T iGPU), tag `latest-arl-h`, 100 % GPU:

| Model | Prefill | Decode |
|---|---|---|
| `llama3.2:3b` (Q4_K_M) | 1249 tok/s | **24.3 tok/s** |
| `gpt-oss:20b` (MXFP4) | 288 – 1106 tok/s | **12.8 tok/s** |
| `gemma4:e4b` | 361 tok/s | **16.1 tok/s** |
| `gemma-4-26B-A4B-it-qat-q4_0` (MoE) | 184 tok/s | **14.3 tok/s** |

More numbers and how they were measured: [README](https://github.com/Dosperado74/ollarc-intel#status).

## Quick start

The host needs a recent kernel (Arrow Lake ≥ 6.11) and the Intel GPU firmware
(Debian: `firmware-intel-graphics`; Ubuntu, Fedora, Proxmox VE: already included).
`ls /dev/dri` must show `renderD128`. Details: [host setup](https://github.com/Dosperado74/ollarc-intel/blob/main/docs/host-setup.md).

```bash
docker run -d --name ollama --restart unless-stopped \
  --device /dev/dri \
  --group-add "$(stat -c %g /dev/dri/renderD128)" \
  -v ollama:/root/.ollama -p 11434:11434 \
  {{IMAGE}}:latest

docker exec ollama ollama run llama3.2:3b
docker exec ollama ollama ps        # -> PROCESSOR 100% GPU
```

With Open WebUI: use the [docker-compose.yml](https://github.com/Dosperado74/ollarc-intel/blob/main/docker-compose.yml)
from the repository. Proxmox VE LXC: [Proxmox guide](https://github.com/Dosperado74/ollarc-intel/blob/main/docs/proxmox.md).

## Tags

| Tag | Kernels | For |
|---|---|---|
| `latest` | JIT (SPIR-V) | **recommended**, every supported Intel GPU |
| `latest-arl-h` | AOT `arl-h` | Arrow Lake-H iGPU (Core Ultra 200H, Arc 140T / 130T) |
| `latest-dg2` | AOT `acm-g10,acm-g11` | dedicated Arc A-series (A770, A750, A580, A380, A310) |
| `latest-bmg` | AOT `bmg-g21` | dedicated Arc B-series (B580, B570, Arc Pro B50 / B60) |

Every tag also exists per Ollama version, e.g. `0.40.15`, `0.40.15-arl-h`.
AOT images only shorten the first model load; inference speed is the same as JIT.

## Help

- Is the GPU used? [diagnostics](https://github.com/Dosperado74/ollarc-intel/blob/main/docs/diagnostics.md)
- Known problems and fixes: [known issues](https://github.com/Dosperado74/ollarc-intel/blob/main/docs/known-issues.md)
- Share your numbers: [benchmark form](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml)

MIT license. Not affiliated with Ollama or Intel.
