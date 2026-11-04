#!/usr/bin/env bash
# Find which part of a model computes wrongly on the SYCL GPU.
#
# Starts a separate llama-server inside the ollama container with the model's
# blob and keeps selected tensors on the CPU (--override-tensor). Greedy output
# of each variant is compared with a CPU-only reference.
#
#   ./diagnostics/bisect-tensors.sh                 # gpt-oss:20b
#   MODEL=qwen3.8:latest ./diagnostics/bisect-tensors.sh
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL="${MODEL:-gpt-oss:20b}"
PROMPT="${PROMPT:-<|start|>user<|message|>Erzähl mir was über Köln.<|end|><|start|>assistant}"
N="${N:-200}"

# free the GPU: unload everything Ollama has loaded
for m in $(docker compose exec -T ollama ollama ps | awk 'NR>1{print $1}'); do
  docker compose exec -T ollama ollama stop "$m" >/dev/null
done

BLOB=$(docker compose exec -T ollama ollama show "$MODEL" --modelfile | awk '/^FROM \//{print $2; exit}')
[[ -n "$BLOB" ]] || { echo "model $MODEL not found"; exit 1; }
echo "model: $MODEL"
echo "blob : $BLOB"
echo

docker compose exec -T -e BLOB="$BLOB" -e PROMPT="$PROMPT" -e N="$N" ollama bash -s <<'EOS'
set -u
export LD_LIBRARY_PATH=/usr/lib/ollama:/usr/lib/ollama/sycl:${LD_LIBRARY_PATH:-}
export GGML_BACKEND_PATH=/usr/lib/ollama/sycl/libggml-sycl.so
PORT=18080

run() {
  local name="$1"; shift
  /usr/lib/ollama/llama-server -m "$BLOB" --port $PORT --host 127.0.0.1 -c 4096 \
      --no-webui --offline "$@" >/tmp/ls.log 2>&1 &
  local pid=$!
  for _ in $(seq 1 180); do
    curl -fs 127.0.0.1:$PORT/health >/dev/null 2>&1 && break
    kill -0 $pid 2>/dev/null || break
    sleep 1
  done
  local body
  body=$(printf '{"prompt":%s,"n_predict":%s,"temperature":0,"stream":false}' \
         "$(printf '%s' "$PROMPT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" "$N")
  local out
  out=$(curl -s 127.0.0.1:$PORT/completion -d "$body" | sed -E 's/.*"content":"(([^"\\]|\\.)*)".*/\1/' | sed 's/\\n/ /g')
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  local offl
  offl=$(grep -oE "offloaded [0-9]+/[0-9]+ layers" /tmp/ls.log | head -1)
  printf '=== %s  [%s]\n    start: %s\n    end  : %s\n\n' "$name" "${offl:-?}" "${out:0:110}" "${out: -110}"
}

run "REF  alles CPU"                 -ngl 0
run "A    alles GPU"                 -ngl 99
run "B    GPU, MoE-Experten auf CPU" -ngl 99 -ot "ffn_.*_exps=CPU"
run "C    GPU, Attention auf CPU"    -ngl 99 -ot "attn_.*=CPU"
run "D    GPU, Router/Gate auf CPU"  -ngl 99 -ot "ffn_gate_inp.*=CPU"
run "E    GPU, ohne Flash-Attention" -ngl 99 -fa off
EOS
