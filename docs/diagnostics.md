# Diagnostics

Tools to find out whether the GPU is used and whether it computes correctly. Run them
in the directory that holds `docker-compose.yml`.

## Is the GPU detected and used?

```bash
docker compose exec ollama sycl-ls                            # [level_zero:gpu] Intel(R) Arc(TM) Graphics
docker compose logs ollama | grep "inference compute"         # library=SYCL ... type=iGPU available=...
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

## Correctness of single ops: `test-backend-ops`

llama.cpp's own test runs every ggml op on the GPU and on the CPU and compares the
results. The image adds test cases with the exact gpt-oss expert shapes.

```bash
docker build -t ollarc-tbo -f diagnostics/test-backend-ops.Dockerfile .   # 15–30 min
./diagnostics/check-ops.sh                                    # ops used by gpt-oss and friends
./diagnostics/check-ops.sh MUL_MAT FLASH_ATTN_EXT             # selected ops
```

Output: `ok=` / `fail=` per op, plus the first failing cases.

## Which part of a model breaks: `diagnostics/bisect-tensors.sh`

Starts a separate `llama-server` on the model's blob inside the container, keeps
selected tensors on the CPU (`--override-tensor`) and compares greedy output with a
CPU-only reference.

```bash
./diagnostics/bisect-tensors.sh                               # gpt-oss:20b, tensor groups
MODEL=qwen3.8:latest ./diagnostics/bisect-tensors.sh
SUITE=kernels N=60 ./diagnostics/bisect-tensors.sh            # single expert tensors + kernel switches
```

How to read it: the variant whose output matches the CPU reference names the part
that computes wrongly on the GPU. Example (gpt-oss with AOT kernels): only "MoE experts
on CPU" matched, which led to the 4 GB buffer issue in
[known-issues.md](known-issues.md#3-models-above-4-gb-compute-garbage-with-aot-kernels).

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

## Upstream reproduction: AOT builds and models > 4 GB

Plain llama.cpp (no Ollama) built three times — JIT, AOT `arl-h` as upstream ships it,
and AOT with [`900-sycl-aot-4gb-buffers.patch`](../patches/llama.cpp/900-sycl-aot-4gb-buffers.patch) —
run on the official `ggml-org/gpt-oss-20b-GGUF`:

```bash
docker build -t ollarc-repro -f diagnostics/repro-aot-4gb.Dockerfile .   # 30–60 min
./diagnostics/repro-aot-4gb.sh                                          # downloads ~12 GB once
```

Expected on an Arc 140T: `jit` and `aot-fixed` answer normally, `aot` prints garbage.

