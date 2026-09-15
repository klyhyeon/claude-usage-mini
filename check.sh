#!/bin/bash
# Self-check for the usage-response parser. No test framework needed.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc \
  Sources/UsageAPI.swift \
  Sources/CookieJar.swift \
  Sources/CodexUsageAPI.swift \
  Sources/CodexMenuLabel.swift \
  Checks/main.swift \
  -o .build/parsecheck
./.build/parsecheck
