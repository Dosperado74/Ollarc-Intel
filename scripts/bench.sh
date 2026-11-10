#!/usr/bin/env bash
# Quick tokens/s benchmark against a running Ollama (ollarc-intel, Vulkan, ... any).
#   ./scripts/bench.sh                     # default models
#   ./scripts/bench.sh qwen3:8b llama3.2:3b
#   OLLAMA_URL=http://nuc:11434 ./scripts/bench.sh
set -euo pipefail
URL="${OLLAMA_URL:-http://localhost:11434}"
MODELS=("$@"); [[ ${#MODELS[@]} -gt 0 ]] || MODELS=(llama3.2:3b qwen3:8b)
PROMPT="${PROMPT:-Explain in about 300 words how a transformer language model generates text.}"
RUNS="${RUNS:-3}"
NUM_PREDICT="${NUM_PREDICT:-256}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

echo "ollama $(curl -fsS "$URL/api/version" | jq -r .version 2>/dev/null || echo unknown)"
printf '%-28s %10s %10s %10s %10s\n' MODEL "prefill" "decode" "load(s)" "first(s)"
for m in "${MODELS[@]}"; do
  if ! curl -fsS "$URL/api/show" -d "{\"model\":\"$m\"}" >/dev/null 2>&1; then
    echo "  pulling $m ..." >&2
    curl -fsS "$URL/api/pull" -d "{\"model\":\"$m\",\"stream\":false}" >/dev/null
  fi
  # warm-up (model load + SYCL kernel JIT)
  echo "  $m: loading / warm-up ..." >&2
  # first(s): wall time of this first request = model load + kernel JIT if not loaded yet
  w=$(curl -fsS "$URL/api/generate" -d "{\"model\":\"$m\",\"prompt\":\"hi\",\"stream\":false,\"options\":{\"num_predict\":1}}")
  first=$(jq -n --argjson r "$w" '$r.total_duration/1e9')
  pp=0; tg=0; ld=0
  for i in $(seq "$RUNS"); do
    echo "  $m: run $i/$RUNS (${NUM_PREDICT} tokens) ..." >&2
    r=$(curl -fsS "$URL/api/generate" -d "$(jq -nc --arg m "$m" --arg p "$PROMPT" \
          --argjson n "$NUM_PREDICT" \
          '{model:$m,prompt:$p,stream:false,think:false,options:{num_predict:$n,seed:1,temperature:0}}')")
    pp=$(jq -n --argjson a "$pp" --argjson r "$r" '$a + ($r.prompt_eval_count / ($r.prompt_eval_duration/1e9))')
    tg=$(jq -n --argjson a "$tg" --argjson r "$r" '$a + ($r.eval_count / ($r.eval_duration/1e9))')
    ld=$(jq -n --argjson a "$ld" --argjson r "$r" '$a + ($r.load_duration/1e9)')
  done
  printf '%-28s %8.1f/s %8.1f/s %10.2f %10.2f\n' "$m" \
    "$(jq -n "$pp/$RUNS")" "$(jq -n "$tg/$RUNS")" "$(jq -n "$ld/$RUNS")" "$first"
done
echo
curl -fsS "$URL/api/ps" | jq -r '.models[] | "\(.name): \(.size_vram/1e9|floor) GB on GPU of \(.size/1e9|floor) GB"' 2>/dev/null || true
