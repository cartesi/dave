#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 1 ]] && [ "$1" == "graphics" ]; then
    # process doom graphics during compute process
    cd lua_poc/doom_showcase/ && make
    cd -
    rm -rf /app/snapshots/*
    ./lua_poc/doom_showcase/process_doom_graphics.lua &
fi

exec ./lua_poc/prt_compute.lua
