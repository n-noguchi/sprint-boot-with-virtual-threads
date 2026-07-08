#!/usr/bin/env bash
set -euo pipefail

# Git Bash (MSYS2) が /scripts のような Unix パスを Windows パスに変換するのを防ぐ。
# Linux/macOS では無害(未定義として扱われるため影響しない)。
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
mkdir -p results

PATTERNS=(
  "api1-off_api2-off:false:false"
  "api1-on_api2-off:true:false"
  "api1-off_api2-on:false:true"
  "api1-on_api2-on:true:true"
)

SELECTED="${1:-}"

wait_ready() {
  local port="$1"
  local path="$2"
  for _ in $(seq 1 30); do
    if curl -sf "http://localhost:${port}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

run_pattern() {
  local name="$1"
  local api1_vt="$2"
  local api2_vt="$3"

  echo ""
  echo "===== Pattern: ${name} (api1 vt=${api1_vt}, api2 vt=${api2_vt}) ====="
  export API1_VT="$api1_vt"
  export API2_VT="$api2_vt"

  docker compose up -d --build api1 api2

  if ! wait_ready 8082 /api2; then
    echo "api2 not ready" >&2
    docker compose down
    return 1
  fi
  if ! wait_ready 8081 /api1; then
    echo "api1 not ready" >&2
    docker compose down
    return 1
  fi
  echo "Both services ready. Starting k6..."

  docker compose run --rm k6 run /scripts/script.js \
    "--summary-export=/results/${name}.json" 2>&1 | tee "results/${name}.log" || true

  docker compose down
}

for p in "${PATTERNS[@]}"; do
  IFS=':' read -r name api1_vt api2_vt <<< "$p"
  if [[ -n "$SELECTED" && "$SELECTED" != "$name" ]]; then
    continue
  fi
  run_pattern "$name" "$api1_vt" "$api2_vt" || echo "Pattern ${name} failed, continuing..."
done

echo ""
echo "All done. Results in ./results"
