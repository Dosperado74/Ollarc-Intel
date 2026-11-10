#!/usr/bin/env bash
# A/B test of runtime environment variables. Recreates the ollama container once per
# variant, runs scripts/bench.sh and a short output check, then prints a summary.
# Run it in the directory that holds docker-compose.yml. Your compose files are not
# changed; at the end (also on Ctrl-C or an error) the container is recreated with
# your normal configuration.
#
#   ./scripts/ab-env.sh baseline UR_L0_USE_IMMEDIATE_COMMANDLISTS=1
#   ./scripts/ab-env.sh baseline SYCL_CACHE_PERSISTENT=1 SYCL_CACHE_PERSISTENT=1
#   MODELS="llama3.2:3b gpt-oss:20b" RUNS=3 ./scripts/ab-env.sh baseline A=1,B=2
#
# Each argument is one variant: "baseline" (no extra variables) or VAR=value[,VAR=value...].
# The first variant also pays for reading the model from disk: start with "baseline baseline".
set -euo pipefail
BENCH="$(cd "$(dirname "$0")" && pwd)/bench.sh"
SERVICE="${OLLAMA_SERVICE:-ollama}"
export OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
read -ra MODELS <<< "${MODELS:-llama3.2:3b}"
CHECK_PROMPT="${CHECK_PROMPT:-Name the capital of France and of Japan in one sentence.}"
if [[ $# -eq 0 ]]; then sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; fi
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
for variant in "$@"; do   # validate everything before touching the container
  [[ "$variant" == "baseline" ]] && continue
  IFS=',' read -ra kvs <<< "$variant"
  for kv in "${kvs[@]}"; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || { echo "invalid variant '$variant' (expected baseline or VAR=value[,VAR=value...])" >&2; exit 1; }
  done
done

# the compose files docker compose would use without -f
base=()
if [[ -n "${COMPOSE_FILE:-}" ]]; then
  IFS="${COMPOSE_PATH_SEPARATOR:-:}" read -ra cf <<< "$COMPOSE_FILE"
  for f in "${cf[@]}"; do base+=(-f "$f"); done
elif [[ -f docker-compose.yml ]]; then
  base=(-f docker-compose.yml)
  [[ -f docker-compose.override.yml ]] && base+=(-f docker-compose.override.yml)
else
  echo "no docker-compose.yml in $(pwd)" >&2; exit 1
fi

tmp=$(mktemp -d)
restore() {
  echo ">> restoring the normal configuration of '$SERVICE'" >&2
  docker compose "${base[@]}" up -d --force-recreate --no-deps "$SERVICE" >/dev/null 2>&1 \
    || echo "!! restore failed, run: docker compose up -d --force-recreate $SERVICE" >&2
  rm -rf "$tmp"
}
trap restore EXIT
trap 'exit 130' INT TERM

wait_ready() {
  for _ in $(seq 120); do curl -fsS "$OLLAMA_URL/api/version" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "!! ollama did not come up within 120 s" >&2; return 1
}

summary=""
n=0
for variant in "$@"; do
  n=$((n + 1))
  args=("${base[@]}")
  vars=()
  if [[ "$variant" != "baseline" ]]; then
    IFS=',' read -ra vars <<< "$variant"
    { echo "services:"; echo "  $SERVICE:"; echo "    environment:"
      for kv in "${vars[@]}"; do
        printf '      - %s\n' "$(jq -nc --arg s "$kv" '$s')"
      done; } > "$tmp/v$n.yml"
    args+=(-f "$tmp/v$n.yml")
  fi

  echo ">> [$n/$#] $variant" >&2
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  docker compose "${args[@]}" up -d --force-recreate --no-deps "$SERVICE" >/dev/null
  wait_ready
  # make sure the variables really reached the container
  for kv in "${vars[@]}"; do
    got=$(docker compose "${args[@]}" exec -T "$SERVICE" printenv "${kv%%=*}" 2>/dev/null || true)
    [[ "$got" == "${kv#*=}" ]] || { echo "!! ${kv%%=*} is '$got' in the container, expected '${kv#*=}'" >&2; exit 1; }
  done

  out=$("$BENCH" "${MODELS[@]}") || out="!! bench.sh failed"
  check=""
  for m in "${MODELS[@]}"; do
    r=$(curl -fsS "$OLLAMA_URL/api/generate" -d "$(jq -nc --arg m "$m" --arg p "$CHECK_PROMPT" \
          '{model:$m,prompt:$p,stream:false,think:false,options:{num_predict:40,seed:1,temperature:0}}')" \
        | jq -r '.response' | tr '\n' ' ' | cut -c1-100) || r="!! request failed"
    check+="  check $m: $r"$'\n'
  done
  errs=$(docker compose "${args[@]}" logs --since "$since" "$SERVICE" 2>&1 \
         | grep -ciE 'segfault|abort|exception|UR_RESULT_ERROR|out of memory|error loading' || true)
  cache=$(docker compose "${args[@]}" exec -T "$SERVICE" sh -c 'du -sh /root/.ollama/sycl-cache 2>/dev/null | cut -f1' || true)

  block="### [$n] $variant"$'\n'"$(grep -vE '^ollama |^$' <<< "$out" || true)"$'\n'"$check"
  block+="  log errors: $errs${cache:+   sycl-cache: $cache}"$'\n'
  summary+="$block"$'\n'
  printf '%s\n' "$block" >&2
done

echo
echo "== summary ($(date '+%F %T'), models: ${MODELS[*]}) =="
printf '%s' "$summary"
