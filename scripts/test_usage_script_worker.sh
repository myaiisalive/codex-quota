#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp /tmp/UsageScriptWorkerRegression.XXXXXX)"
trap 'rm -f "$OUTPUT"' EXIT

swiftc -D DEBUG -parse-as-library \
  "$ROOT/Sources/CodexQuota/BoundedIO.swift" \
  "$ROOT/Sources/CodexQuota/UsageScriptRunner.swift" \
  "$ROOT/Tests/UsageScriptWorkerRegression.swift" \
  -o "$OUTPUT"

"$OUTPUT"
