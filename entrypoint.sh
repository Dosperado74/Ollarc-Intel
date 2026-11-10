#!/usr/bin/env bash
# ollarc-intel entrypoint: sanity-check the Intel GPU, then hand over to ollama.
set -euo pipefail

if [[ "${1:-serve}" == "serve" ]]; then
    if ! compgen -G "/dev/dri/renderD*" >/dev/null; then
        echo "ollarc: WARNING: no /dev/dri/renderD* device in the container." >&2
        echo "ollarc:          start it with '--device /dev/dri' (see docker-compose.yml)." >&2
        echo "ollarc:          ollama will fall back to CPU." >&2
    elif [[ "${OLLARC_QUIET:-0}" != "1" ]] && command -v sycl-ls >/dev/null; then
        echo "ollarc: SYCL devices:" >&2
        sycl-ls 2>/dev/null | sed 's/^/ollarc:   /' >&2 || true
    fi
fi

exec /usr/bin/ollama "$@"
