#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apple-feishu-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$TEST_DIR/cache" \
  "$ROOT_DIR/Sources/FeishuCLI.swift" "$ROOT_DIR/Tests/FeishuCLITests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$ROOT_DIR/Tests/fixtures/fake-lark-cli.py"
