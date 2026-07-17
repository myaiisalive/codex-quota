#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp /tmp/QuotaReaderRegression.XXXXXX)"
trap 'rm -f "$OUTPUT"' EXIT

swiftc -parse-as-library \
  "$ROOT/Sources/CodexQuota/QuotaModel.swift" \
  "$ROOT/Sources/CodexQuota/QuotaReader.swift" \
  "$ROOT/Tests/QuotaReaderRegression.swift" \
  -o "$OUTPUT"

"$OUTPUT"
