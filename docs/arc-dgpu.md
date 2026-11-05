# Dedicated Intel Arc cards (A- and B-series)

ollarc-intel is built and tested primarily for **Intel iGPUs**. Dedicated Arc cards use
the same SYCL backend (llama.cpp lists the Arc A770 and B580 as supported) and work with
the same images. This page only covers what is different on a dedicated card.

> [!NOTE]
> The maintainer has no dedicated Arc card, so the `latest-dg2` / `latest-bmg` images
> are built by CI but **not yet verified on real hardware**. If something does not work,
> fall back to `latest` (JIT) and please open an issue with card, kernel, image tag and
> the output of `scripts/bench.sh`. Working results are just as welcome.

## Cards and images

| Card | GPU | Kernel driver | Min. kernel | Image (`OLLARC_TAG`) |
|---|---|---|---|---|
| Arc A770, A750, A580 | Alchemist ACM-G10 | `i915` | 6.2 | `latest-dg2` or `latest` |
| Arc A380, A310 | Alchemist ACM-G11 | `i915` | 6.2 | `latest-dg2` or `latest` |
| Arc B580, B570, Arc Pro B50 / B60 | Battlemage BMG-G21 | `xe` | 6.12 | `latest-bmg` or `latest` |
| any other Intel GPU | | | | `latest` |

`latest` compiles the GPU kernels once when a model is loaded (JIT) and runs on every
card. `latest-dg2` / `latest-bmg` ship them precompiled (AOT), which only shortens that
first load. Inference speed is the same. Pinned versions exist as well, e.g.
`0.40.14-dg2`.

## 1. Host

The host needs the kernel driver and the GPU firmware, exactly like for an iGPU
(see [host-setup.md](host-setup.md)), plus Resizable BAR.

| Host | Arc A-series | Arc B-series |
|---|---|---|
| Debian 13 (kernel 6.12) | ✅ with `firmware-intel-graphics` | ✅ with `firmware-intel-graphics` |
| Debian 12 (kernel 6.1) | needs a backports kernel | needs a backports kernel and newer firmware, so use Debian 13 |
| Ubuntu 24.04 (HWE kernel 6.14+) / 26.04 | ✅ | ✅ |
| Fedora (current) | ✅ | ✅ |
| Proxmox VE 9 | ✅ | ✅ |

**Resizable BAR.** Enable *Above 4G Decoding* and *Re-Size BAR Support* in the BIOS.
The A-series in particular gets much slower without it. Check it:

```bash
sudo lspci -vv -d 8086: | grep -E "VGA|Display|current size"   # BAR 2: current size: 16GB (= VRAM size)
```

Find the card's render node (an iGPU, if present, is usually `renderD128`, so the Arc
card is `renderD129`):

```bash
lspci -D -d 8086: | grep -iE "vga|display"
ls -l /dev/dri/by-path/
```

## 2. Start

Same as the [quick start](../README.md#quick-start-docker--open-webui), with the image
tag for the card in `.env`:

```bash
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" > .env   # all render nodes share the "render" group
echo "OLLARC_TAG=latest-dg2" >> .env                          # A-series; B-series: latest-bmg
docker compose up -d
```

## 3. CPU with an iGPU: use only the Arc card

Most Intel CPUs have an iGPU (all except the `F` models). The image makes every GPU
visible (`ONEAPI_DEVICE_SELECTOR=level_zero:*`), so Ollama may spread a model over the
fast Arc card **and** the slow iGPU. Find the Level Zero id of the Arc card:

```bash
docker compose exec ollama sycl-ls
# [level_zero:gpu][level_zero:0] ... Intel(R) Graphics [0x7d55]      <- iGPU
# [level_zero:gpu][level_zero:1] ... Intel(R) Arc(TM) A770 Graphics  <- Arc card
```

and allow only that one in a `docker-compose.override.yml` next to `docker-compose.yml`:

```yaml
services:
  ollama:
    environment:
      - ONEAPI_DEVICE_SELECTOR=level_zero:1
```

`docker compose up -d` applies it. The id follows the PCI order, so check it again after
hardware changes.

## 4. Check

```bash
docker compose logs ollama | grep "inference compute"   # library=SYCL ... description="Intel(R) Arc(TM) A770 Graphics" ... type=discrete
docker compose exec ollama ollama ps                    # PROCESSOR: 100% GPU
```

Only the Arc card should appear in the `inference compute` lines.

## 5. Free VRAM reporting

The image default `GGML_SYCL_GET_MEM_API=1` is chosen for iGPUs
([known-issues.md §2](known-issues.md#2-igpu-reports-almost-no-free-memory)). On some
dedicated cards (e.g. the A770) this SYCL API cannot read the free VRAM and reports the
total VRAM instead. That is fine for a card that does nothing else. If a desktop or other
programs also use the card and models fail to load with out-of-memory errors, query the
real free VRAM through Level Zero instead:

```yaml
services:
  ollama:
    environment:
      - ONEAPI_DEVICE_SELECTOR=level_zero:1   # if the system also has an iGPU (step 3)
      - GGML_SYCL_GET_MEM_API=0
      - ZES_ENABLE_SYSMAN=1
```

On a dedicated card Level Zero Sysman reports the VRAM correctly; the iGPU problem from
known-issues §2 does not apply. If the system also has an iGPU, keep the selector from
step 3 so the iGPU is not queried this way.

## 6. Which models fit

Unlike an iGPU, a dedicated card has its own VRAM. The model plus its context
(about 1–2 GB at 8K) must fit into it; otherwise Ollama keeps some layers on the CPU,
which is much slower (`ollama ps` then shows e.g. `30%/70% CPU/GPU`).

| VRAM | Cards | Fits completely (Q4, 8K context) |
|---|---|---|
| 6 GB | A380 | 3B–4B models; 7B/8B only with a small context |
| 8 GB | A750, A580, A770 8 GB | 7B–8B |
| 10–12 GB | B570, B580 | up to ~14B |
| 16 GB | A770 16 GB, Arc Pro B50 | 14B–20B, e.g. `gpt-oss:20b` |
| 24 GB | Arc Pro B60 | ~32B dense, or 26B–30B MoE |

Token generation is limited by memory bandwidth. A750/A770/B580 have roughly 4–5× the
bandwidth of dual-channel DDR5, so the same model decodes several times faster than on an
iGPU. The tips in [tuning.md](tuning.md) apply unchanged (`Q4_0` quants, flash attention
plus `OLLAMA_KV_CACHE_TYPE=q8_0` for long contexts).

## 7. Proxmox VE

Use an LXC exactly as in [proxmox.md](proxmox.md), but pass through the Arc card's
nodes instead of the iGPU's. Look them up on the host with `ls -l /dev/dri/by-path/`,
e.g.:

```ini
dev0: /dev/dri/renderD129,gid=993
dev1: /dev/dri/card1,gid=44
```

Inside the container the node keeps its name (`renderD129`), so set
`RENDER_GID=$(stat -c %g /dev/dri/renderD129)` there.

## Build it yourself

```bash
docker build --build-arg SYCL_DEVICE_ARCH=acm-g10,acm-g11 -t ollarc-intel:dg2 .   # Arc A-series
docker build --build-arg SYCL_DEVICE_ARCH=bmg-g21 -t ollarc-intel:bmg .           # Arc B-series
```

The >4 GB buffer fix ([known-issues.md §3](known-issues.md#3-models-above-4-gb-compute-garbage-with-aot-kernels))
is applied to every AOT build, whatever the architecture.
