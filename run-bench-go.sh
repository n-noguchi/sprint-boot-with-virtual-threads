#!/usr/bin/env bash
set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
mkdir -p results

# Go / Gin: goroutine(無制限=軽量) と 並行制限(同時10=重い相当) の 2 パターン
PATTERNS=(
  "go-unlimited:0"
  "go-limited-10:10"
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
  local max_conc="$2"

  echo ""
  echo "===== Pattern: ${name} (Go/Gin, max_concurrency=${max_conc}) ====="
  export GO_MAX_CONCURRENCY="$max_conc"
  export BASE_URL="http://api1-go:8080"

  docker compose up -d --build api1-go api2-go

  if ! wait_ready 8092 /api2; then
    echo "api2-go not ready" >&2
    docker compose down
    return 1
  fi
  if ! wait_ready 8091 /api1; then
    echo "api1-go not ready" >&2
    docker compose down
    return 1
  fi
  echo "Both services ready. Starting k6..."

  docker compose run --rm k6 run /scripts/script.js \
    "--summary-export=/results/${name}.json" 2>&1 | tee "results/${name}.log" || true

  docker compose down
}

for p in "${PATTERNS[@]}"; do
  IFS=':' read -r name max_conc <<< "$p"
  if [[ -n "$SELECTED" && "$SELECTED" != "$name" ]]; then
    continue
  fi
  run_pattern "$name" "$max_conc" || echo "Pattern ${name} failed, continuing..."
done

echo ""
echo "All done. Results in ./results"
