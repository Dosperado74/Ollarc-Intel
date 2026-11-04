#!/usr/bin/env bash
# Run test-backend-ops for the ops a model family uses and print a summary.
#   ./diagnostics/check-ops.sh                 # ops used by gpt-oss (default)
#   ./diagnostics/check-ops.sh MUL_MAT SOFT_MAX
set -uo pipefail
IMG="${IMG:-ollarc-tbo}"
GID="$(stat -c %g /dev/dri/renderD128)"
OPS=("$@"); [[ ${#OPS[@]} -gt 0 ]] || OPS=(MUL_MAT_ID ADD_ID GLU SOFT_MAX FLASH_ATTN_EXT MUL_MAT ROPE RMS_NORM ARGSORT GET_ROWS)
for op in "${OPS[@]}"; do
  out=$(docker run --rm --device /dev/dri --group-add "$GID" "$IMG" test -b SYCL0 -o "$op" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')
  pass=$(grep -cE "OK$" <<<"$out"); fail=$(grep -cE "FAIL$" <<<"$out")
  printf '%-16s ok=%-5s fail=%s\n' "$op" "$pass" "$fail"
  grep -E "FAIL$" <<<"$out" | head -5 | sed 's/^/    /'
done
