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
| `GGML_SYCL_GET_MEM_API` | `1` | free memory via SYCL; `0` uses Level Zero Sysman, which on iGPUs reports only the host's unused RAM (page cache and container limits ignored) |
| `ZES_ENABLE_SYSMAN` | `0` | Level Zero Sysman; only needed for multi-GPU setups with `GGML_SYCL_GET_MEM_API=0` |
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | allows allocations > 4 GiB (large models) |
| `GGML_SYCL_DYNAMIC_PRECISION` | `F16` | set to `BF16` if a model outputs garbage/NaN (F16 overflow) |

## Choosing models

- Token generation on an iGPU is **memory-bandwidth bound**: smaller quants are faster.
- The SYCL backend has the most optimizations for **`Q4_0`** (reorder + XMX). Many models
  in the Ollama registry also have a `…-q4_0` tag, e.g. `ollama pull llama3.1:8b-instruct-q4_0`.
- `Q4_K_M` (the Ollama default) works too, but is usually a bit slower than `Q4_0` on SYCL.

## Slow first start?

The universal image (`latest`) compiles the GPU kernels the first time a model is loaded
(JIT). On Arrow Lake-H, `latest-arl-h` avoids this because the kernels are precompiled.
llama.cpp explicitly does **not** recommend `SYCL_CACHE_PERSISTENT=1`.
