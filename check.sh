#!/bin/bash
# Self-check for the usage-response parser. No test framework needed.
set -euo pipefail
cd "$(dirname "$0")"
swiftc Sources/UsageAPI.swift Sources/CookieJar.swift Checks/main.swift -o .build/parsecheck
./.build/parsecheck
