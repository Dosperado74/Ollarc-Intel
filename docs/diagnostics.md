# Diagnostics

Checks whether the GPU is used and how fast it is. Run them
in the directory that holds `docker-compose.yml`.

## Is the GPU detected and used?

```bash
docker compose exec ollama sycl-ls                            # [level_zero:gpu] Intel(R) Arc(TM) Graphics
docker compose logs ollama | grep "inference compute"         # library=SYCL ... type=iGPU (Arc card: discrete) available=...
docker compose exec ollama ollama ps                          # PROCESSOR: 100% GPU
docker compose logs ollama | grep -E "using device SYCL0|offloaded"   # offloaded N/N layers to GPU
```

Live GPU load: run `nvtop` or `intel_gpu_top` (package `intel-gpu-tools`) **on the
Proxmox host**. Inside an unprivileged LXC they cannot see the GPU.

## Speed: `scripts/bench.sh`

```bash
./scripts/bench.sh llama3.2:3b qwen3.8:latest
RUNS=1 NUM_PREDICT=64 ./scripts/bench.sh qwen3.8:latest      # quick run
```

Prints prefill and decode tokens/s per model, `load(s)` of the measured runs and
`first(s)`, the time of the first request (model load plus kernel JIT, if the model was
not loaded yet). Thinking is disabled for the measurement. Please share your results with the [benchmark form](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml).

## Trying runtime switches

`docker-compose.override.yml` sets extra environment variables without touching
`docker-compose.yml`:

```bash
cat > docker-compose.override.yml <<'EOF'
services:
  ollama:
    environment:
      - OLLAMA_FLASH_ATTENTION=0
EOF
docker compose up -d --force-recreate ollama
rm docker-compose.override.yml   # undo
```

The useful ggml-sycl switches are listed in [tuning.md](tuning.md).

## A/B testing runtime switches

`scripts/ab-env.sh` automates the override above for several variants and compares them.
For each variant it

1. recreates only the `ollama` container with a temporary compose override (your
   `docker-compose.yml` and `docker-compose.override.yml` are not changed, Open WebUI keeps running),
2. checks that every variable really arrived in the container,
3. runs `bench.sh`, then a short deterministic answer check per model,
4. counts suspicious log lines (`segfault`, `abort`, `UR_RESULT_ERROR`, `out of memory`, …).

At the end, also on Ctrl-C or an error, the container is recreated with your normal
configuration. Run it where `docker compose` runs (on Proxmox: inside the LXC), in the
directory that holds `docker-compose.yml`. Needs `curl` and `jq`.

```bash
MODELS="llama3.2:3b gpt-oss:20b" ./scripts/ab-env.sh baseline baseline OLLAMA_FLASH_ATTENTION=1
MODELS="llama3.2:3b" RUNS=5 ./scripts/ab-env.sh baseline baseline OLLAMA_FLASH_ATTENTION=1,OLLAMA_KV_CACHE_TYPE=q8_0
```

Each argument is one variant: `baseline` (no extra variables) or `VAR=value`, several
variables separated by commas (`A=1,B=2`). Invalid arguments are rejected before anything is
touched.

| Setting | Default | Meaning |
|---|---|---|
| `MODELS` | `llama3.2:3b` | space-separated models; missing ones are pulled |
| `RUNS`, `NUM_PREDICT` | `3`, `256` | passed on to `bench.sh` |
| `CHECK_PROMPT` | capital of France and Japan | prompt of the answer check (40 tokens, temperature 0) |
| `OLLAMA_URL` | `http://localhost:11434` | where Ollama is reachable from the host |
| `OLLAMA_SERVICE` | `ollama` | compose service name |
| `COMPOSE_FILE` | `docker-compose.yml` (+ override) | your compose files, if they are named differently |

Example summary, one block per variant (illustrative numbers):

```text
### [3] OLLAMA_FLASH_ATTENTION=1
MODEL                           prefill     decode    load(s)   first(s)
llama3.2:3b                    1251.3/s     24.6/s       0.09       3.41
llama3.2:3b: 2 GB on GPU of 2 GB
  check llama3.2:3b: The capital of France is Paris, and the capital of Japan is Tokyo.
  log errors: 0
```

How to read it:

- **Start with `baseline` twice.** The first run also reads the model from disk. The difference
  between the two baselines is the measurement noise; a variant must beat it clearly.
- **`first(s)`** contains the model load and, on the JIT image, the kernel compilation. The other
  columns are averages over `RUNS` runs with the model already loaded.
- **Answer check:** it must read normally. `GGGG…`, repeated words or an empty answer mean the
  variant computes garbage, whatever the speed says.
- **`log errors`** must not be higher than for `baseline`.
- Keep a variant only if it wins across several runs and then runs a few days in normal use
  without problems. Results are welcome in the
  [benchmark form](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml).

Switches that were evaluated and deliberately not used are listed in
[tuning.md](tuning.md#deliberately-not-used).
