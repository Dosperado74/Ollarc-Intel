#!/usr/bin/env bash
# Runs the three llama-server builds from repro-aot-4gb.Dockerfile on the same model
# and prints what an upstream bug report needs: versions, device, and the start of each
# greedy completion.
#
#   ./diagnostics/repro-aot-4gb.sh                       # ggml-org/gpt-oss-20b-GGUF (~12 GB, downloaded once)
#   MODEL=<hf-repo> ./diagnostics/repro-aot-4gb.sh
set -euo pipefail
IMG="${IMG:-ollarc-repro}"
CACHE="${CACHE:-$HOME/llama-cache}"          # model download cache on the host
MODEL="${MODEL:-ggml-org/gpt-oss-20b-GGUF}"
mkdir -p "$CACHE"
GID="$(stat -c %g /dev/dri/renderD128)"

# keep the GPU memory free: unload Ollama models if Ollama runs here
if docker ps --format '{{.Names}}' | grep -qx ollama; then
  for m in $(docker exec ollama ollama ps | awk 'NR>1{print $1}'); do docker exec ollama ollama stop "$m" >/dev/null; done
fi

docker run --rm -i --device /dev/dri --group-add "$GID" \
  -v "$CACHE":/root/.cache/llama.cpp -e MODEL="$MODEL" "$IMG" bash -s <<'EOS'
set -u
PORT=18080
PROMPT='<|start|>user<|message|>Tell me about the city of Cologne in two sentences.<|end|><|start|>assistant'

echo "### llama.cpp version"
/opt/repro/aot/llama-server --version 2>&1 | grep -iE "version|built" | head -2
echo
echo "### SYCL device"
sycl-ls 2>/dev/null | grep -i level_zero
echo

run() {
  local v="$1"
  /opt/repro/$v/llama-server -hf "$MODEL" -ngl 99 -c 4096 --port $PORT --host 127.0.0.1 \
      --no-webui >/tmp/$v.log 2>&1 &
  local pid=$!
  # first run downloads the model, so allow plenty of time
  for _ in $(seq 1 3600); do
    curl -fs 127.0.0.1:$PORT/health >/dev/null 2>&1 && break
    kill -0 $pid 2>/dev/null || break
    sleep 1
  done
  local body out
  body=$(printf '{"prompt":"%s","n_predict":64,"temperature":0,"stream":false}' "$(printf '%s' "$PROMPT" | sed 's/"/\\"/g')")
  out=$(curl -s 127.0.0.1:$PORT/completion -d "$body" | sed -E 's/.*"content":"(([^"\\]|\\.)*)".*/\1/' | sed 's/\\n/ /g')
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "### $v"
  grep -E "GGML_SYCL_DEVICE_ARCH|offloaded|SYCL0 model buffer size" /tmp/$v.log | head -3
  echo "output: ${out:0:200}"
  echo
}

run jit
run aot
run aot-fixed
EOS
