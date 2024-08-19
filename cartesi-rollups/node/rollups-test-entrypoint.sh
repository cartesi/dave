#!/usr/bin/env bash
set -euo pipefail

exec env RUST_LOG="info" cargo test
