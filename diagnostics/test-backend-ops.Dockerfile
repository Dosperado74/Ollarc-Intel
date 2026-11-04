# syntax=docker/dockerfile:1.7
#
# llama.cpp test-backend-ops for the SYCL backend: runs every ggml op on the
# Intel GPU and on the CPU and reports ops whose results differ.
#
#   docker build -t ollarc-tbo -f diagnostics/test-backend-ops.Dockerfile .
#   docker run --rm --device /dev/dri --group-add "$(stat -c %g /dev/dri/renderD128)" \
#       ollarc-tbo test -b SYCL0 -o MUL_MAT_ID
#
# LLAMA_CPP_VERSION defaults to the build Ollama pins (see UPSTREAM_VERSION).

ARG ONEAPI_VERSION=2026.2.0
ARG UBUNTU_VERSION=26.04
FROM intel/oneapi:${ONEAPI_VERSION}-devel-ubuntu${UBUNTU_VERSION}
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake ninja-build git ca-certificates libze-dev libze1 libze-intel-gpu1 intel-opencl-icd \
    && rm -rf /var/lib/apt/lists/*
ARG LLAMA_CPP_VERSION=b11963
RUN git -c advice.detachedHead=false clone --depth 1 --branch "${LLAMA_CPP_VERSION}" \
        https://github.com/ggml-org/llama.cpp /llama.cpp
WORKDIR /llama.cpp
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx \
        -DGGML_SYCL=ON -DGGML_SYCL_TARGET=INTEL -DGGML_SYCL_F16=ON \
        -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=ON -DLLAMA_CURL=OFF \
    && cmake --build build --target test-backend-ops -- -l $(nproc)
# same libumf fix as the runtime image
RUN find /opt/intel/oneapi -maxdepth 3 -type d -path '*/umf/*/lib' > /etc/ld.so.conf.d/zz-oneapi-umf.conf && ldconfig
ENV ONEAPI_DEVICE_SELECTOR=level_zero:* UR_L0_ENABLE_RELAXED_ALLOCATION_LIMITS=1
ENTRYPOINT ["/llama.cpp/build/bin/test-backend-ops"]
CMD ["test", "-b", "SYCL0"]
