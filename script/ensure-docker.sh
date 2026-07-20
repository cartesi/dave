#!/usr/bin/env bash
# The kms tests run testcontainers, and a sleeping Docker Desktop
# fails them with connection noise that reads like a code problem
# (it cost three debugging detours in one week). Preflight instead:
# quick no-op when the daemon answers; on macOS, wake Docker Desktop
# and wait; elsewhere, fail naming the fix.
set -u

if docker info > /dev/null 2>&1; then
    exit 0
fi

if [ "$(uname)" = "Darwin" ] && command -v open > /dev/null; then
    echo "[ensure-docker] docker daemon not answering; waking Docker Desktop..."
    open -a Docker || {
        echo "[ensure-docker] could not launch Docker Desktop; start docker manually" >&2
        exit 1
    }
    for _ in $(seq 1 60); do
        if docker info > /dev/null 2>&1; then
            echo "[ensure-docker] docker is up"
            exit 0
        fi
        sleep 2
    done
    echo "[ensure-docker] Docker Desktop did not come up within 120s" >&2
    exit 1
fi

echo "[ensure-docker] docker daemon not answering; start it and retry (the kms tests need testcontainers)" >&2
exit 1
