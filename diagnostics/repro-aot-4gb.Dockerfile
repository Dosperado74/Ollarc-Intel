# syntax=docker/dockerfile:1.7
#
# Reproduction for the upstream report "SYCL AOT builds break models > 4 GB".
# Plain llama.cpp (no Ollama), three builds of llama-server:
#   jit        GGML_SYCL_DEVICE_ARCH unset (JIT)                -> correct
#   aot        GGML_SYCL_DEVICE_ARCH=arl-h, upstream            -> garbage for models > 4 GB
#   aot-fixed  same + patches/llama.cpp/900-sycl-aot-4gb-buffers -> correct
#
#   docker build -t ollarc-repro -f diagnostics/repro-aot-4gb.Dockerfile .
#   ./diagnostics/repro-aot-4gb.sh

ARG ONEAPI_VERSION=2026.2.0
ARG UBUNTU_VERSION=26.04

FROM intel/oneapi:${ONEAPI_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS base
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake ninja-build git ca-certificates curl libssl-dev \
        libze-dev libze1 libze-intel-gpu1 intel-opencl-icd intel-ocloc \
    && rm -rf /var/lib/apt/lists/*
# libumf.so.1 is not on the linker path in the oneAPI images
RUN find /opt/intel/oneapi -maxdepth 3 -type d -path '*/umf/*/lib' > /etc/ld.so.conf.d/zz-oneapi-umf.conf && ldconfig
ARG LLAMA_CPP_VERSION=v0.9.0
RUN git -c advice.detachedHead=false clone --depth 1 --branch "${LLAMA_CPP_VERSION}" \
        https://github.com/ggml-org/llama.cpp /src
COPY patches/llama.cpp/900-sycl-aot-4gb-buffers.patch /tmp/fix.patch
RUN cp -r /src /src-fixed && cd /src-fixed && git apply /tmp/fix.patch
ENV LLAMA_CMAKE_ARGS="-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
    -DGGML_SYCL=ON -DGGML_SYCL_TARGET=INTEL -DGGML_SYCL_F16=ON -DGGML_NATIVE=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF"

FROM base AS jit
RUN cmake -S /src -B /b ${LLAMA_CMAKE_ARGS} && cmake --build /b --target llama-server

FROM base AS aot
ARG SYCL_DEVICE_ARCH=arl-h
RUN cmake -S /src -B /b ${LLAMA_CMAKE_ARGS} -DGGML_SYCL_DEVICE_ARCH=${SYCL_DEVICE_ARCH} \
    && cmake --build /b --target llama-server

FROM base AS aot-fixed
ARG SYCL_DEVICE_ARCH=arl-h
RUN cmake -S /src-fixed -B /b ${LLAMA_CMAKE_ARGS} -DGGML_SYCL_DEVICE_ARCH=${SYCL_DEVICE_ARCH} \
    && cmake --build /b --target llama-server

FROM base
COPY --from=jit       /b/bin/llama-server /opt/repro/jit/llama-server
COPY --from=aot       /b/bin/llama-server /opt/repro/aot/llama-server
COPY --from=aot-fixed /b/bin/llama-server /opt/repro/aot-fixed/llama-server
ENV ONEAPI_DEVICE_SELECTOR=level_zero:* \
    UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1 \
    GGML_SYCL_GET_MEM_API=1
