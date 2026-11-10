#!/usr/bin/env bash
# ollarc-intel entrypoint: sanity-check the Intel GPU, then hand over to ollama.
set -euo pipefail

# Opt-in persistent SYCL kernel cache (SYCL_CACHE_PERSISTENT=1, default off).
# The JIT image compiles the GPU kernels on every container start; with the cache
# the compiled kernels survive restarts. llama.cpp warns that mixing cached kernels
# of an older SYCL binary with a newer one can crash, so the cache directory is keyed
# on everything that produces the kernels (libggml-sycl, SYCL runtime, GPU compiler):
# a new image gets a fresh directory and directories of older images are removed.
# Any failure here disables the cache and never blocks the start.
sycl_cache_setup() {
    [[ "${SYCL_CACHE_PERSISTENT:-0}" == "1" ]] || return 0
    if [[ -n "${SYCL_CACHE_DIR:-}" ]]; then
        echo "ollarc: SYCL kernel cache: ${SYCL_CACHE_DIR} (SYCL_CACHE_DIR set, not managed)" >&2
        return 0
    fi
    local root="${OLLARC_SYCL_CACHE_ROOT:-/root/.ollama/sycl-cache}" key d
    key=$({
        sha256sum /usr/lib/ollama/sycl/libggml-sycl.so /opt/intel/oneapi/redist/lib/libsycl.so.* 2>/dev/null
        dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null | grep -E '^(libze|intel-|libigc|libigdfcl|libigdgmm)' || true
    } | sha256sum | cut -c1-16) || key=""
    if [[ ! "$key" =~ ^[0-9a-f]{16}$ ]] || ! mkdir -p "${root}/${key}" 2>/dev/null; then
        echo "ollarc: WARNING: SYCL kernel cache could not be set up, running without it." >&2
        export SYCL_CACHE_PERSISTENT=0
        return 0
    fi
    for d in "${root}"/*/; do
        d="${d%/}"
        [[ "${d##*/}" =~ ^[0-9a-f]{16}$ && "${d##*/}" != "$key" ]] && rm -rf -- "$d"
    done
    export SYCL_CACHE_DIR="${root}/${key}"
    echo "ollarc: SYCL kernel cache: ${SYCL_CACHE_DIR}" >&2
}

if [[ "${1:-serve}" == "serve" ]]; then
    if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
        echo "ollarc: WARNING: no /dev/dri/renderD* device in the container." >&2
        echo "ollarc:          start it with '--device /dev/dri' (see docker-compose.yml)." >&2
        echo "ollarc:          ollama will fall back to CPU." >&2
    elif [[ "${OLLARC_QUIET:-0}" != "1" ]] && command -v sycl-ls >/dev/null; then
        echo "ollarc: SYCL devices:" >&2
        sycl-ls 2>/dev/null | sed 's/^/ollarc:   /' >&2 || true
    fi
    sycl_cache_setup || true
fi

exec /usr/bin/ollama "$@"
