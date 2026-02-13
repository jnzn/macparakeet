#!/usr/bin/env bash
set -euo pipefail

# Local CI parity check: clean build + full parallel test run.
swift package clean
swift test --parallel
