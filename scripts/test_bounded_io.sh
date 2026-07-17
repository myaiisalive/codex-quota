#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/BoundedIORegression.XXXXXX)"
OUTPUT="$WORK/test"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; [[ -n "$SERVER_PID" ]] && wait "$SERVER_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT

dd if=/dev/zero of="$WORK/small.bin" bs=1024 count=1 status=none
dd if=/dev/zero of="$WORK/large.bin" bs=1024 count=2048 status=none
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" > /dev/null 2>&1 &
SERVER_PID=$!

swiftc -parse-as-library \
  "$ROOT/Sources/CodexQuota/BoundedIO.swift" \
  "$ROOT/Tests/BoundedIORegression.swift" \
  -o "$OUTPUT"

for _ in {1..50}; do
  if curl --silent --fail "http://127.0.0.1:$PORT/small.bin" > /dev/null; then
    break
  fi
  sleep 0.05
done

"$OUTPUT" \
  "http://127.0.0.1:$PORT/small.bin" \
  "http://127.0.0.1:$PORT/large.bin"
