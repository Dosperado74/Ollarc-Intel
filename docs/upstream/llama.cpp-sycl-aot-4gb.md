# Upstream report: llama.cpp SYCL AOT builds break models > 4 GB

Ready to post at <https://github.com/ggml-org/llama.cpp/issues/new>.
Title and body below.

---

**Title:** `SYCL: AOT builds (GGML_SYCL_DEVICE_ARCH) produce garbage for models > 4 GB, missing -ze-intel-greater-than-4GB-buffer-required`

**Body:**

### Name and Version

llama.cpp b11963 (also present in b12086), SYCL backend, oneAPI 2026.2, Ubuntu 26.04,
compute-runtime 26.35 (Level Zero 1.17).

### Operating systems

Linux

### GGML backends

SYCL

### Hardware

Intel Core Ultra 9 285H, Arc 140T iGPU (Arrow Lake-H, `8086:7d51`), 96 GB RAM.

### Problem description & steps to reproduce

With `-DGGML_SYCL_DEVICE_ARCH=arl-h` (AOT, `spir64_gen`), any model whose GPU buffers
exceed 4 GB produces garbage. `gpt-oss-20b` (13 GB) outputs only `GGGGGGGG…` with
`-ngl 99`. The same build without `GGML_SYCL_DEVICE_ARCH` (JIT) is correct.

`ggml/src/ggml-sycl/CMakeLists.txt` adds `-Xs -ze-intel-greater-than-4GB-buffer-required`
only for JIT builds and otherwise prints:

```
Skipping -ze-intel-greater-than-4GB-buffer-required for spir64_gen AOT
```

So the AOT kernels are compiled with 32-bit (stateful) addressing, which overflows in
buffers above 4 GB.

Observations:
- Keeping the MoE experts on the CPU (`-ot "ffn_.*_exps=CPU"`) brings the GPU part
  below 4 GB and the output is correct. Keeping only one of `gate/up/down_exps` on the
  CPU is not enough.
- `test-backend-ops -b SYCL0` passes for `MUL_MAT_ID`, `ADD_ID`, `SWIGLU_OAI`,
  `MUL_MAT_VEC_FUSION`, including the exact gpt-oss shapes (32 experts, 4 used,
  2880×2880, 1/79/512 tokens), because the test tensors are small.
- None of the runtime switches helps (`GGML_SYCL_ENABLE_OPT=0`, `…_FUSION=0`,
  `…_ESIMD=0`, `…_XMX_GATHER_TYPES=0`, `…_PRIORITIZE_DMMV=1`, `SYCL_UR_USE_LEVEL_ZERO_V2=0`).

### Proposed fix

Pass the same option to `ocloc` for AOT builds:

```diff
-        "SHELL:-Xsycl-target-backend=spir64_gen \"-device ${GGML_SYCL_DEVICE_ARCH}\""
+        "SHELL:-Xsycl-target-backend=spir64_gen \"-device ${GGML_SYCL_DEVICE_ARCH} -options -ze-intel-greater-than-4GB-buffer-required\""
```

in both `target_compile_options` and `target_link_options` of the
`if (GGML_SYCL_DEVICE_ARCH)` block. **Verified:** with this change the AOT (`arl-h`)
build gives a correct answer for gpt-oss-20b on the Arc 140T. The patch still applies to
v0.9.0 (b12110), where the `Skipping …` branch is unchanged. Full patch:
<https://github.com/Dosperado74/ollarc-intel/blob/main/patches/llama.cpp/900-sycl-aot-4gb-buffers.patch>

### Relevant log output

`llama-server -m gpt-oss-20b.gguf -ngl 99`, `/completion` with
`"prompt": "<|start|>user<|message|>Erzähl mir was über Köln.<|end|><|start|>assistant"`,
`"temperature": 0`:

```
AOT (arl-h):            GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG…
AOT, experts on CPU:    <|channel|>analysis<|message|>The user says: "Erzähl mir was über Köln." They want something about Cologne. …
JIT (same model via Ollama): correct German answer about Cologne
CPU only (-ngl 0):      <|channel|>analysis<|message|>The user says: "Erzähl mir was über Köln." They want something about Cologne. …
```

---

### Additional findings (separate issues, optional)

`test-backend-ops -b SYCL0` on the same Arc 140T (JIT build) also reports:

```
FLASH_ATTN_EXT(hsk=256,hsv=256,nh=2,nr23=[16,1],kv=1025,nb=64,mask=1,sinks=0,max_bias=0,logit_softcap=0,prec=f32,type_K=q8_0,type_V=q8_0,permute=[0,2,1,3],kv_view=1,v_is_view_of_k=0,n_kv_max=0): FAIL  ERR = 1.189
FLASH_ATTN_EXT(hsk=256,hsv=256,nh=1,nr23=[12,2],kv=8192,nb=67,mask=1,sinks=0,max_bias=0,logit_softcap=0,prec=f32,type_K=f16,type_V=f16,permute=[0,1,2,3],kv_view=1,v_is_view_of_k=0,n_kv_max=512): FAIL  ERR = 0.993
MUL_MAT(type_a=bf16,type_b=f32,m=1057,n=1,k=129,bs=[1,3],nr=[1,1],per=[0,2,1,3],k_v=0,o=1,src_overlap=0,m_v=0,pad=0): FAIL  ERR = 0.639
MUL_MAT(type_a=bf16,type_b=f32,m=1057,n=1,k=129,bs=[1,3],nr=[4,1],per=[0,2,1,3],k_v=0,o=1,src_overlap=0,m_v=0,pad=0): FAIL  ERR = 0.664
```
