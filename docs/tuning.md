# Tuning für Intel iGPUs

Alle Variablen werden im `environment:`-Block des `ollama`-Service gesetzt.

## Ollama

| Variable | Empfehlung | Wirkung |
|---|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` | Flash Attention im SYCL-Backend; weniger Speicher für lange Kontexte |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` (braucht FA) | halbiert den KV-Cache-Speicher, minimal Qualitätsverlust |
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Standard-Kontext; größer = mehr RAM |
| `OLLAMA_KEEP_ALIVE` | `30m` | Modell bleibt geladen, kein erneutes Laden/JIT |
| `OLLAMA_NUM_PARALLEL` | `1` | auf einer iGPU meist am schnellsten |

## SYCL / oneAPI

| Variable | Default im Image | Wirkung |
|---|---|---|
| `ONEAPI_DEVICE_SELECTOR` | `level_zero:*` | welche GPUs sichtbar sind, z. B. `level_zero:0` |
| `ZES_ENABLE_SYSMAN` | `1` | echte Free-Memory-Abfrage → besseres Scheduling |
| `UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS` | `1` | Allokationen > 4 GiB (große Modelle) |
| `GGML_SYCL_DYNAMIC_PRECISION` | `F16` | `BF16`, wenn ein Modell Unsinn/NaN ausgibt (F16-Überlauf) |

## Modellwahl

- Die iGPU ist bei der Token-Generierung **speicherbandbreiten-limitiert**: kleinere Quants = schneller.
- Das SYCL-Backend hat die meisten Optimierungen für **`Q4_0`** (Reorder + XMX). Viele Modelle
  gibt es in der Ollama-Registry auch als `…-q4_0`-Tag, z. B. `ollama pull llama3.1:8b-instruct-q4_0`.
- `Q4_K_M` (Ollama-Standard) läuft ebenfalls, ist aber auf SYCL meist etwas langsamer als `Q4_0`.

## Erster Start langsam?

Das universelle Image (`latest`) kompiliert die GPU-Kernels beim ersten Laden eines Modells
(JIT). Auf Arrow Lake-H vermeidet `latest-arl-h` das (Kernels sind vorkompiliert).
`SYCL_CACHE_PERSISTENT=1` wird von llama.cpp ausdrücklich **nicht** empfohlen.
