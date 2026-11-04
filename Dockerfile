# syntax=docker/dockerfile:1.7
#
# ollarc-intel — upstream Ollama + llama.cpp SYCL backend for Intel GPUs
#
#   docker build -t ollarc-intel .
#   docker build --build-arg OLLAMA_VERSION=v0.40.14 -t ollarc-intel:0.40.14 .
#
# OLLAMA_VERSION    upstream git tag of github.com/ollama/ollama (default: see UPSTREAM_VERSION)
# LLAMA_CPP_VERSION empty = the llama.cpp build Ollama pins; e.g. b12086 for a newer SYCL backend
# SYCL_DEVICE_ARCH empty = JIT (default, works on every Intel GPU).
#                  arl-h / mtl-h / lnl-m / ... = ahead-of-time kernels for one GPU family.
#                  Upstream llama.cpp builds AOT kernels without >4 GB buffer support
#                  (models above ~4 GB compute garbage); patches/llama.cpp/900-* fixes that.

ARG ONEAPI_VERSION=2026.2.0
ARG UBUNTU_VERSION=26.04
ARG GO_VERSION=1.26

#
# 1) Upstream source + ollarc patches
#
FROM alpine/git:latest AS source
ARG OLLAMA_VERSION=v0.40.14
WORKDIR /src
RUN git -c advice.detachedHead=false clone --depth 1 --branch "${OLLAMA_VERSION}" \
        https://github.com/ollama/ollama.git ollama
COPY patches /patches
# patches/*.patch change Ollama; patches/llama.cpp/*.patch change llama.cpp itself:
# Ollama applies every llama/compat/*.patch to the fetched llama.cpp in filename order
RUN cd ollama && for p in /patches/*.patch; do \
        echo "applying ${p}" && git apply --whitespace=nowarn "${p}" || exit 1; \
    done \
    && cp /patches/llama.cpp/*.patch llama/compat/
# Optional: build against a newer llama.cpp than the one Ollama pins
# (e.g. --build-arg LLAMA_CPP_VERSION=b12086). Ollama's compat patch must still apply.
ARG LLAMA_CPP_VERSION=
RUN if [ -n "${LLAMA_CPP_VERSION}" ]; then echo "${LLAMA_CPP_VERSION}" > ollama/LLAMA_CPP_VERSION; fi \
    && echo "llama.cpp: $(cat ollama/LLAMA_CPP_VERSION)"

#
# 2) Native build: CPU llama-server (gcc) + SYCL ggml backend (icpx)
#
FROM intel/oneapi:${ONEAPI_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS native
ARG SYCL_DEVICE_ARCH=
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake ninja-build git ccache gcc g++ libze-dev ca-certificates curl \
        intel-ocloc \
    && rm -rf /var/lib/apt/lists/*
ENV CMAKE_GENERATOR=Ninja
WORKDIR /src
COPY --from=source /src/ollama/LLAMA_CPP_VERSION .
COPY --from=source /src/ollama/llama/server llama/server
COPY --from=source /src/ollama/llama/compat llama/compat
COPY --from=source /src/ollama/cmake cmake

# CPU runner: llama-server, libggml-base, libllama and all CPU variants
RUN --mount=type=cache,target=/root/.ccache \
    CC=gcc CXX=g++ cmake -S llama/server --preset cpu \
        -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build build/llama-server-cpu -- -l $(nproc) \
    && cmake --install build/llama-server-cpu --component llama-server --strip

# SYCL backend module: lib/ollama/sycl/libggml-sycl.so
RUN --mount=type=cache,target=/root/.ccache \
    cmake -S llama/server --preset sycl \
        ${SYCL_DEVICE_ARCH:+-DGGML_SYCL_DEVICE_ARCH=${SYCL_DEVICE_ARCH}} \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    && cmake --build build/llama-server-sycl -- -l $(nproc) \
    && cmake --install build/llama-server-sycl --component llama-server --strip \
    && ls -la dist/lib/ollama dist/lib/ollama/sycl

#
# 3) Go build
#
FROM golang:${GO_VERSION}-trixie AS gobuild
ARG OLLAMA_VERSION=v0.40.14
# GOTOOLCHAIN=auto fetches the exact toolchain from go.mod if it is newer
ENV CGO_ENABLED=1 GOTOOLCHAIN=auto
WORKDIR /go/src/github.com/ollama/ollama
COPY --from=source /src/ollama/go.mod /src/ollama/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY --from=source /src/ollama .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie \
        -ldflags "-w -s -X=github.com/ollama/ollama/version.Version=${OLLAMA_VERSION#v}-ollarc -X=github.com/ollama/ollama/server.mode=release" \
        -o /out/ollama .

#
# 4) Runtime: oneAPI runtime libs (SYCL/UR, oneMKL, oneDNN, TBB) + Intel GPU user-space driver
#
FROM intel/oneapi-runtime:${ONEAPI_VERSION}-devel-ubuntu${UBUNTU_VERSION}
ARG OLLAMA_VERSION=v0.40.14
ARG SYCL_DEVICE_ARCH=
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
        libze1 libze-intel-gpu1 intel-opencl-icd clinfo \
    && rm -rf /var/lib/apt/lists/*
COPY --from=gobuild /out/ollama /usr/bin/ollama
COPY --from=native /src/dist/lib/ollama /usr/lib/ollama
# sycl-ls: lists the SYCL/Level Zero devices the container can see (diagnostics)
COPY --from=native /opt/intel/oneapi/compiler/latest/bin/sycl-ls /usr/local/bin/sycl-ls
COPY entrypoint.sh /usr/local/bin/ollarc-entrypoint

# The oneAPI runtime image only registers oneapi/redist/lib with the dynamic
# linker, but the Level Zero UR adapter needs libumf.so.1 from oneapi/umf/<ver>/lib.
# Without it SYCL silently sees no GPU ("No platforms found").
# Fail the build if any SYCL / Level Zero dependency does not resolve.
RUN set -e; \
    find /opt/intel/oneapi -maxdepth 3 -type d -path '*/umf/*/lib' > /etc/ld.so.conf.d/zz-oneapi-umf.conf; \
    ldconfig; \
    missing=$(for f in /opt/intel/oneapi/redist/lib/libur_loader.so.0 \
                       /opt/intel/oneapi/redist/lib/libur_adapter_level_zero*.so.0 \
                       /usr/lib/ollama/sycl/libggml-sycl.so; do \
                  LD_LIBRARY_PATH=/usr/lib/ollama ldd "$f" | grep "not found" | sed "s|^|$f: |"; \
              done); \
    if [ -n "$missing" ]; then echo "unresolved SYCL/Level Zero libraries:"; echo "$missing"; exit 1; fi

LABEL org.opencontainers.image.title="ollarc-intel" \
      org.opencontainers.image.description="Upstream Ollama with the llama.cpp SYCL backend for Intel Arc / Xe GPUs" \
      org.opencontainers.image.source="https://github.com/Dosperado74/ollarc-intel" \
      org.opencontainers.image.licenses="MIT" \
      io.ollarc.ollama-version="${OLLAMA_VERSION}" \
      io.ollarc.sycl-device-arch="${SYCL_DEVICE_ARCH}"

# Sensible defaults for Intel iGPUs (all overridable at runtime)
# GGML_SYCL_GET_MEM_API=1: query free memory via SYCL instead of Level Zero
# Sysman. On iGPUs Sysman reports the host's MemFree (no page cache, ignores
# container limits), so Ollama would plan far too little GPU memory.
ENV OLLAMA_HOST=0.0.0.0:11434 \
    OLLAMA_MODELS=/root/.ollama/models \
    ONEAPI_DEVICE_SELECTOR=level_zero:* \
    GGML_SYCL_GET_MEM_API=1 \
    ZES_ENABLE_SYSMAN=0 \
    UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1

EXPOSE 11434
VOLUME ["/root/.ollama"]
ENTRYPOINT ["/usr/local/bin/ollarc-entrypoint"]
CMD ["serve"]
