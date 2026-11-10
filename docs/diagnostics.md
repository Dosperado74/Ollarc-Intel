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

`scripts/ab-env.sh` does the same automatically for several variants: it recreates the
`ollama` container once per variant (with a temporary compose override, your files stay
unchanged), checks that the variables arrived in the container, runs `bench.sh` and a short
answer check, counts error lines in the log and prints a summary. At the end, also on
Ctrl-C, the container is recreated with your normal configuration.

```bash
# immediate command lists (Meteor Lake / Arrow Lake)
MODELS="llama3.2:3b gpt-oss:20b" ./scripts/ab-env.sh baseline baseline UR_L0_USE_IMMEDIATE_COMMANDLISTS=1
# persistent kernel cache (latest image): 2nd cache run should show a much lower first(s)
./scripts/ab-env.sh baseline baseline SYCL_CACHE_PERSISTENT=1 SYCL_CACHE_PERSISTENT=1
```

Start with `baseline` twice: the first run also reads the model from disk. Several
variables per variant are separated by commas (`A=1,B=2`). A variant is only worth keeping if
the answer check reads normally (no `GGGG…`), `log errors` stays at the baseline value and
the numbers are better across several runs.
