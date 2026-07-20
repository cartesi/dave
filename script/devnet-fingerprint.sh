#!/usr/bin/env bash
# The devnet fingerprint: what a deployed state.json was built from.
# Committed tree hashes of both contract packages plus any uncommitted
# drift under them. Coarse on purpose - it can call a fresh state
# stale (a cosmetic script edit), never a stale state fresh. A stale
# devnet fails e2e runs with a winner-commitment mismatch, the
# scariest message in the node (incident 2026-07-14, docs/test-harness.md).
set -euo pipefail
cd "${BASH_SOURCE%/*}/.."
{
    git rev-parse HEAD:cartesi-rollups/contracts HEAD:prt/contracts
    git status --porcelain cartesi-rollups/contracts prt/contracts
} | shasum -a 256 | cut -d' ' -f1
