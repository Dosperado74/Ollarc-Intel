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

Prints prefill and decode tokens/s per model. Thinking is disabled for the
measurement. Please share results in an issue: model, quant, CPU/iGPU and the numbers.

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
