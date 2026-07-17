#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp /tmp/CodexTaskSessionReaderRegression.XXXXXX)"
trap 'rm -f "$OUTPUT"' EXIT

swiftc -D DEBUG -parse-as-library \
  "$ROOT/Sources/CodexQuota/BoundedIO.swift" \
  "$ROOT/Sources/CodexQuota/QuotaModel.swift" \
  "$ROOT/Sources/CodexQuota/QuotaReader.swift" \
  "$ROOT/Sources/CodexQuota/CodexTaskSession.swift" \
  "$ROOT/Tests/CodexTaskSessionReaderRegression.swift" \
  -o "$OUTPUT"

"$OUTPUT"
