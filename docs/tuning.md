# Tuning for Intel iGPUs

Set all variables in the `environment:` block of the `ollama` service.

## Ollama

| Variable | Recommendation | Effect |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | flash attention in the SYCL backend; less memory for long contexts |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` (needs FA) | halves KV cache memory with minimal quality loss |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | default context; larger means more RAM |
| `OLLAMA_KEEP_ALIVE` | `30m` | keeps the model loaded, so there is no reload or JIT |
| `OLLAMA_NUM_PARALLEL` | `1` | usually fastest on an iGPU |

## SYCL / oneAPI

| Variable | Image default | Effect |
|---|---|---|
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:*` | which GPUs are visible, e.g. `level_zero:0` |
| `GGML_SYCL_GET_MEM_API` | `1` | free memory via SYCL; `0` uses Level Zero Sysman, which on iGPUs reports only the host's unused RAM (page cache and container limits ignored). Dedicated Arc cards: see [arc-dgpu.md §5](arc-dgpu.md#5-free-vram-reporting) |
| `ZES_ENABLE_SYSMAN` | `0` | Level Zero Sysman; only needed for multi-GPU setups with `GGML_SYCL_GET_MEM_API=0` |
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | allows allocations > 4 GiB (large models) |
| `GGML_SYCL_DYNAMIC_PRECISION` | `F16` | set to `BF16` if a model outputs garbage/NaN (F16 overflow) |

## Experimental (off by default)

Not set in the image. Measure them on your machine with
[`scripts/ab-env.sh`](diagnostics.md#ab-testing-runtime-switches) before keeping one.

| Variable | Effect | Notes |
|---|---|---|
| `SYCL_CACHE_PERSISTENT=1` | keeps the JIT-compiled GPU kernels across container restarts, so the first model load after a restart skips the JIT | only the `latest` (JIT) image benefits, AOT images have nothing to compile; does not change inference speed. See [below](#persistent-kernel-cache) |
| `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1` | Level Zero immediate command lists (`0` off, `1` per queue, `2` per thread) | changes something only on Meteor Lake / Arrow Lake, where Intel switched it **off** on Linux "due to driver limitations" ([intel/llvm#19950](https://github.com/intel/llvm/pull/19950), Sept 2025). Already on for Arc A-series; Arc B-series and Lunar Lake use the v2 adapter, which always uses them |

### Persistent kernel cache

llama.cpp [advises against](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md)
`SYCL_CACHE_PERSISTENT=1`: when the SYCL binary changes, old cached kernels mixed with new
code can crash. ollarc-intel updates its images daily, so the entrypoint guards against
exactly that when the variable is set:

- the cache lives in the Ollama volume under `/root/.ollama/sycl-cache/<key>`, where `<key>` is a
  hash of `libggml-sycl.so`, the SYCL runtime and the installed GPU compiler/driver packages;
- a new image therefore starts with an empty directory, and directories of older images are deleted;
- if the directory cannot be created, the container starts without the cache;
- with your own `SYCL_CACHE_DIR` the entrypoint leaves the cache alone.

To reset it: `docker compose exec ollama rm -rf /root/.ollama/sycl-cache`.

## Choosing models

- Token generation on an iGPU is **memory-bandwidth bound**: smaller quants are faster.
- The SYCL backend has the most optimizations for **`Q4_0`** (reorder + XMX). Many models
  in the Ollama registry also have a `…-q4_0` tag, e.g. `ollama pull llama3.1:8b-instruct-q4_0`.
- `Q4_K_M` (the Ollama default) works too, but is usually a bit slower than `Q4_0` on SYCL.

## Slow first start?

The `latest` image compiles the GPU kernels the first time a model is loaded (JIT). On
Arrow Lake-H (Core Ultra 200H) use `OLLARC_TAG=latest-arl-h`: its kernels are
precompiled (AOT) for the Arc 140T / 130T. Dedicated Arc cards have their own AOT
images: `latest-dg2` (A-series) and `latest-bmg` (B-series), see
[arc-dgpu.md](arc-dgpu.md). Inference speed is the same either way. With the
`latest` image you can also try the [persistent kernel cache](#persistent-kernel-cache).
