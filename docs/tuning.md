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

## Deliberately not used

Other Intel GPU setups set these; ollarc-intel does not, on purpose. Try them with
[`scripts/ab-env.sh`](diagnostics.md#ab-testing-runtime-switches) if you are curious.

| Variable | Why not |
|---|---|
| `SYCL_CACHE_PERSISTENT=1` | only shortens the first model load (kernel JIT), not inference. llama.cpp [advises against it](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md): cached kernels of an older SYCL binary mixed with a newer one can crash, and the images update daily. The AOT images (`latest-arl-h`, `-dg2`, `-bmg`) solve the same problem without a cache |
| `UR_L0_USE_IMMEDIATE_COMMANDLISTS=1` | Intel switched immediate command lists **off** on Meteor Lake / Arrow Lake under Linux "due to driver limitations" ([intel/llvm#19950](https://github.com/intel/llvm/pull/19950)); forcing them on risks hangs or wrong output for an expected gain of at most a few percent (not measured; token generation is memory-bandwidth bound). Arc A-series already uses them, Arc B-series and Lunar Lake always do |

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
[arc-dgpu.md](arc-dgpu.md). Inference speed is the same either way.
