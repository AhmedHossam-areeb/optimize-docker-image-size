#!/usr/bin/env bash
set -euo pipefail

APP_DIR="./"
RESULTS_DIR="./results"
mkdir -p "$RESULTS_DIR"

fail() {
  echo "[FAIL] $1"
  exit 1
}

pass() {
  echo "[PASS] $1"
}

cleanup() {
  if docker ps --format '{{.Names}}' | grep -q '^bloated-node-test$'; then
    docker rm -f bloated-node-test >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$APP_DIR"

# 1) Required files.
test -f Dockerfile || fail "Dockerfile is missing"
test -f Dockerfile.bad || fail "Dockerfile.bad is missing"
test -f .dockerignore || fail ".dockerignore is missing"
pass "Required files exist"

# 2) .dockerignore must include key exclusions.
for entry in node_modules .git docs tests sample-data README.md; do
  grep -Eq "^${entry}/?$" .dockerignore || fail ".dockerignore missing entry: ${entry}"
done
pass ".dockerignore excludes unnecessary content"

# 3) Multi-stage build check.
from_count=$(grep -ciE '^\s*FROM\s+' Dockerfile)
[ "$from_count" -ge 2 ] || fail "Dockerfile must use multi-stage build (>=2 FROM lines)"
pass "Dockerfile uses multi-stage build"

# 4) Slim/alpine base image check.
grep -qiE '^\s*FROM\s+node:[^ ]*(slim|alpine)' Dockerfile || fail "Dockerfile must use node:*slim or node:*alpine"
pass "Dockerfile uses a slim/alpine base image"

# 5) Cache-friendly ordering check.
pkg_line=$(grep -nE '^\s*COPY\s+package\*\.json\s+\./?$|^\s*COPY\s+package\.json\s+package-lock\.json\s+\./?$' Dockerfile | head -n1 | cut -d: -f1 || true)
src_line=$(grep -nE '^\s*COPY\s+\.\s+\.' Dockerfile | head -n1 | cut -d: -f1 || true)
[ -n "${pkg_line}" ] || fail "Dockerfile must copy package metadata before full source"
[ -n "${src_line}" ] || fail "Dockerfile must include COPY . . in the build stage"
[ "$pkg_line" -lt "$src_line" ] || fail "COPY package*.json must appear before COPY . ."
pass "Dockerfile uses cache-friendly COPY ordering"

# 6) Build baseline and optimized images.
docker build -f Dockerfile.bad -t bloated-node:baseline . >/dev/null
pass "Baseline image builds successfully"
docker build -t bloated-node:optimized . >/dev/null
pass "Optimized image builds successfully"

base_size=$(docker image inspect bloated-node:baseline --format '{{.Size}}')
opt_size=$(docker image inspect bloated-node:optimized --format '{{.Size}}')
reduction=$((100 - (opt_size * 100 / base_size)))

# 7) Runtime test on exposed app port.
docker run -d --rm --name bloated-node-test -p 127.0.0.1::3000 bloated-node:optimized >/dev/null
host_port=""
for _ in $(seq 1 30); do
  host_port=$(docker port bloated-node-test 3000/tcp | awk -F: '{print $2}' | tr -d '[:space:]' || true)
  if [ -n "$host_port" ] && curl -fsS "http://127.0.0.1:${host_port}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

[ -n "$host_port" ] || fail "Could not determine mapped host port"
response=$(curl -fsS "http://127.0.0.1:${host_port}/") || fail "Application did not respond successfully"
echo "$response" | jq -e '.status == "healthy"' >/dev/null || fail "Application response must include {\"status\":\"healthy\"}"
pass "Application responds healthy on container port 3000"

# 8) Ensure docs/tests/sample-data are not in runtime image.
docker run --rm bloated-node:optimized sh -lc 'test ! -d /app/docs && test ! -d /app/tests && test ! -d /app/sample-data' || fail "docs/tests/sample-data should not exist in final image"
pass "Unnecessary files are excluded from final image"

# 9) Size reduction target.
[ "$reduction" -ge 60 ] || fail "Optimized image reduction is ${reduction}% (< 60%)"
pass "Optimized image is at least 60% smaller"

{
  echo "baseline_bytes=${base_size}"
  echo "optimized_bytes=${opt_size}"
  echo "reduction_percent=${reduction}"
} | tee "$RESULTS_DIR/size-comparison.txt" >/dev/null

echo
echo "Validation complete."
echo "Baseline size:  ${base_size} bytes"
echo "Optimized size: ${opt_size} bytes"
echo "Reduction:      ${reduction}%"
