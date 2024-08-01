#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 1 ]] && [ "$1" == "extra_data" ]; then
    # write doom gameplays to `pixels` directory,
    # and generate tournament/hero states to `outputs` directory
    export EXTRA_DATA="true"
    cd lua_poc/doom_showcase/ && make
    cd -
    ./lua_poc/doom_showcase/process_doom_graphics.lua &
fi

exec ./lua_poc/prt_compute.lua
