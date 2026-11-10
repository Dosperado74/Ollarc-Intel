#!/usr/bin/env bash
# Quick tokens/s benchmark against a running Ollama (ollarc-intel, Vulkan, ... any).
#   ./scripts/bench.sh                     # default models
#   ./scripts/bench.sh qwen3:8b llama3.2:3b
#   ./scripts/bench.sh --all               # every installed model, smallest first
#   OLLAMA_URL=http://nuc:11434 ./scripts/bench.sh
# --all skips models that cannot generate text (embedding models) and unloads each
# model after its measurement, so first(s) is a real cold load and RAM stays free.
set -euo pipefail
URL="${OLLAMA_URL:-http://localhost:11434}"
PROMPT="${PROMPT:-Explain in about 300 words how a transformer language model generates text.}"
RUNS="${RUNS:-3}"
NUM_PREDICT="${NUM_PREDICT:-256}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ALL=0
if [[ "${1:-}" == "--all" ]]; then
  ALL=1
  mapfile -t MODELS < <(curl -fsS "$URL/api/tags" | jq -r '.models | sort_by(.size) | .[].name')
  [[ ${#MODELS[@]} -gt 0 ]] || { echo "no models installed" >&2; exit 1; }
else
  MODELS=("$@"); [[ ${#MODELS[@]} -gt 0 ]] || MODELS=(llama3.2:3b qwen3:8b)
fi

row() { printf '%-34s %10s %10s %10s %10s %6s\n' "$@"; }

# prints the result row; returns 1 on a failed request, 2 for a model that cannot generate text
bench_model() {
  local m=$1 show w first r pp=0 tg=0 ld=0 gpu i
  if ! show=$(curl -fsS "$URL/api/show" -d "$(jq -nc --arg m "$m" '{model:$m}')" 2>/dev/null); then
    echo "  pulling $m ..." >&2
    curl -fsS "$URL/api/pull" -d "$(jq -nc --arg m "$m" '{model:$m,stream:false}')" >/dev/null || return 1
    show=$(curl -fsS "$URL/api/show" -d "$(jq -nc --arg m "$m" '{model:$m}')") || return 1
  fi
  # older Ollama versions have no capabilities field: assume the model can generate
  jq -e '(.capabilities // ["completion"]) | index("completion")' <<< "$show" >/dev/null || return 2
  # warm-up; first(s) = wall time of this first request (model load + kernel JIT if not loaded yet)
  echo "  $m: loading / warm-up ..." >&2
  w=$(curl -fsS "$URL/api/generate" -d "$(jq -nc --arg m "$m" \
        '{model:$m,prompt:"hi",stream:false,options:{num_predict:1}}')") || return 1
  first=$(jq -n --argjson r "$w" '$r.total_duration/1e9')
  for i in $(seq "$RUNS"); do
    echo "  $m: run $i/$RUNS (${NUM_PREDICT} tokens) ..." >&2
    r=$(curl -fsS "$URL/api/generate" -d "$(jq -nc --arg m "$m" --arg p "$PROMPT" \
          --argjson n "$NUM_PREDICT" \
          '{model:$m,prompt:$p,stream:false,think:false,options:{num_predict:$n,seed:1,temperature:0}}')") || return 1
    pp=$(jq -n --argjson a "$pp" --argjson r "$r" '$a + ($r.prompt_eval_count / ($r.prompt_eval_duration/1e9))')
    tg=$(jq -n --argjson a "$tg" --argjson r "$r" '$a + ($r.eval_count / ($r.eval_duration/1e9))')
    ld=$(jq -n --argjson a "$ld" --argjson r "$r" '$a + ($r.load_duration/1e9)')
  done
  # share of the model in GPU memory (100% = fully offloaded)
  gpu=$(curl -fsS "$URL/api/ps" | jq -r --arg m "$m" \
        '[.models[] | select(.name == $m or .model == $m)][0] | if . then "\((.size_vram * 100 / .size) | floor)%" else "?" end' 2>/dev/null || echo "?")
  row "$m" "$(printf '%.1f/s' "$(jq -n "$pp/$RUNS")")" "$(printf '%.1f/s' "$(jq -n "$tg/$RUNS")")" \
      "$(printf '%.2f' "$(jq -n "$ld/$RUNS")")" "$(printf '%.2f' "$first")" "$gpu"
}

echo "ollama $(curl -fsS "$URL/api/version" | jq -r .version 2>/dev/null || echo unknown)"
row MODEL prefill decode "load(s)" "first(s)" GPU
for m in "${MODELS[@]}"; do
  rc=0; bench_model "$m" || rc=$?
  case $rc in
    1) row "$m" failed - - - - ;;
    2) echo "  $m: skipped (no text generation, e.g. an embedding model)" >&2 ;;
  esac
  if [[ $ALL == 1 ]]; then
    curl -fsS "$URL/api/generate" -d "$(jq -nc --arg m "$m" '{model:$m,keep_alive:0}')" >/dev/null 2>&1 || true
  fi
done
if [[ $ALL == 0 ]]; then
  echo
  curl -fsS "$URL/api/ps" | jq -r '.models[] | "\(.name): \(.size_vram/1e9|floor) GB on GPU of \(.size/1e9|floor) GB"' 2>/dev/null || true
fi
