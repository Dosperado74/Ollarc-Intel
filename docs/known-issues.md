# Known issues and findings

Everything below was found while bringing up ollarc-intel on an **ASUS NUC 14 Pro+ with a
Core Ultra 9 285H (Arrow Lake-H, Arc 140T iGPU, PCI ID `8086:7d51`)** running
Proxmox VE 9 (kernel 7.0, `i915`), an unprivileged Debian 13 LXC and Docker.
Ollama v0.40.14, llama.cpp b11963, oneAPI 2026.2.

| # | Symptom | Cause | Status |
|---|---|---|---|
| 1 | `sycl-ls`: *No platforms found*, Ollama runs on CPU | oneAPI runtime image does not register `libumf.so.1` with the dynamic linker | **fixed** in the image |
| 2 | `offloaded 0/66 layers to GPU`, `ollama ps` shows `99%/1% CPU/GPU` | Level Zero Sysman reports the host's *MemFree* as free iGPU memory | **fixed** (`GGML_SYCL_GET_MEM_API=1`) |
| 3 | Models > 4 GB answer `GGGGGGGG…` or loop, Ollama aborts with *token repeat limit reached* | AOT (`arl-h`) kernels built without >4 GB buffer support | **fixed** (patch, verified on Arc 140T) |
| 4 | `test-backend-ops`: 2 × `FLASH_ATTN_EXT` fail (`hsk=256`) | SYCL flash attention, head size 256 | open, upstream |
| 5 | `test-backend-ops`: 2 × `MUL_MAT` fail (`bf16`, permuted `src0`) | SYCL BF16 mat-mul on non-contiguous weights | open, upstream |
| 6 | Qwen3.8 27B answers take minutes | dense 27B model + long *thinking* phase on an iGPU | expected, see below |

---

## 1. No Level Zero platform (`libumf.so.1`)

**Symptom**

```
$ sycl-ls --verbose
failed to load adapter 'libur_adapter_level_zero.so.0' with error: libumf.so.1: cannot open shared object file
```

OpenCL (`clinfo`) still sees the GPU, but SYCL finds no Level Zero platform, so
`llama-server --list-devices` fails and Ollama falls back to the CPU.

**Cause** `intel/oneapi-runtime` ships `libumf.so.1` in
`/opt/intel/oneapi/umf/<ver>/lib`, but only `/opt/intel/oneapi/redist/lib` is listed
in `/etc/ld.so.conf.d`. The Unified Runtime Level Zero adapter links against UMF.

**Fix** The Dockerfile adds the UMF directory to `ld.so.conf.d` and fails the build
if any SYCL / Level Zero library stays unresolved.

## 2. iGPU reports almost no free memory

**Symptom**

```
llama_prepare_model_devices: using device SYCL0 (Intel(R) Arc(TM) Graphics) - 1256 MiB free
load_tensors: offloaded 0/66 layers to GPU
```

`free -g` inside the container shows 79 GB available.

**Cause** By default ggml-sycl asks Level Zero Sysman (`zesMemoryGetState`) for free
memory. On an iGPU that is the *host's* `MemFree`: page cache is not counted and
container limits are ignored. After downloading a model the page cache fills the RAM,
"free" drops to about 1 GB, and llama-server's automatic fit puts no layer on the GPU.

**Fix** The image sets `GGML_SYCL_GET_MEM_API=1` (query through SYCL) and
`ZES_ENABLE_SYSMAN=0`. Ollama still caps iGPU memory at the available system RAM.

## 3. Models above 4 GB compute garbage with AOT kernels

**Symptom** `gpt-oss:20b` (13 GB) answers `GGGGGGGG…`; through Ollama the request
fails with `prediction aborted, token repeat limit reached`. Small models
(`llama3.2:3b`, 2 GB) are fine. With the MoE experts kept on the CPU
(`-ot "ffn_.*_exps=CPU"`) the output is correct again.

**Cause** llama.cpp's `ggml/src/ggml-sycl/CMakeLists.txt` passes
`-ze-intel-greater-than-4GB-buffer-required` only for JIT builds and prints
*"Skipping -ze-intel-greater-than-4GB-buffer-required for spir64_gen AOT"* when
`GGML_SYCL_DEVICE_ARCH` is set. AOT kernels then use 32-bit offsets, which overflow in
buffers above 4 GB. Every op passes `test-backend-ops` because its tensors are small.

**How it was found** Keeping groups of tensors on the CPU (`llama-server
--override-tensor`) showed that only "MoE experts on CPU" was correct, which leaves less
than 4 GB on the GPU. No kernel switch helped, all `test-backend-ops` cases (including the
exact gpt-oss shapes) passed, and the JIT image produced correct output.

**Fix**
- `latest` (JIT) was never affected.
- `patches/llama.cpp/900-sycl-aot-4gb-buffers.patch` passes the same option to `ocloc`
  (`-options -ze-intel-greater-than-4GB-buffer-required`). Verified: with the patched
  AOT image, `gpt-oss:20b` gives a correct answer on an Arc 140T, where the unpatched
  AOT image printed only `GGGG…`. `latest-arl-h` is built with it.
- Upstream report: [ggml-org/llama.cpp#31685](https://github.com/ggml-org/llama.cpp/issues/31685)
  (notes: [`docs/upstream/llama.cpp-sycl-aot-4gb.md`](upstream/llama.cpp-sycl-aot-4gb.md)).

## 4. Flash attention with head size 256

`test-backend-ops -b SYCL0 -o FLASH_ATTN_EXT`, 4102 OK / 4 FAIL, e.g.

```
FLASH_ATTN_EXT(hsk=256,hsv=256,nh=2,nr23=[16,1],kv=1025,nb=64,mask=1,…,type_K=q8_0,type_V=q8_0,…): FAIL  (ERR 1.19)
FLASH_ATTN_EXT(hsk=256,hsv=256,nh=1,nr23=[12,2],kv=8192,nb=67,mask=1,…,type_K=f16,type_V=f16,…,n_kv_max=512): FAIL  (ERR 0.99)
```

Models with 256-wide attention heads (Qwen3.8, Gemma) may be affected with long
contexts. If a model degrades with long prompts, try `OLLAMA_FLASH_ATTENTION=0`.

## 5. BF16 mat-mul with permuted weights

`test-backend-ops -b SYCL0 -o MUL_MAT`, 2271 OK / 4 FAIL, e.g.

```
MUL_MAT(type_a=bf16,type_b=f32,m=1057,n=1,k=129,bs=[1,3],nr=[1,1],per=[0,2,1,3],…): FAIL  (ERR 0.64)
```

Only non-contiguous BF16 weights with odd sizes are affected; ordinary model weights
are contiguous.

## 6. Speed expectations on an Arc 140T

Token generation on an iGPU is limited by memory bandwidth (dual-channel DDR5,
≈ 70–80 GB/s usable): each token reads every *active* weight once.

| Model | Type | Expected decode |
|---|---|---|
| `llama3.2:3b` | dense 3B | **24.3 tok/s** measured |
| `qwen3.8:27b` (Q4) | dense 27B, ~16.5 GB active | **3.2–5.9 tok/s** measured; prefill 109 tok/s |
| `gpt-oss:20b` | MoE, ~3.6B active | **12.8 tok/s** measured (10.6 at 6.5K context); prefill **1106 tok/s** |
| `gpt-oss:120b` | MoE, ~5.1B active, ~65 GB | ~1.4× slower than 20b, needs ~65 GB free for the iGPU |

Thinking models (Qwen3.8, gpt-oss) can write thousands of thinking tokens before the
answer. Disable thinking per model in Open WebUI (*Admin → Settings → Models → model →
Advanced Params → `think (Ollama)` → Off*) or append `/no_think` to a Qwen prompt.
