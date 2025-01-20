#!/usr/bin/env bash
set -euo pipefail

# requires lcov - sudo apt-get install lcov
forge coverage --report lcov
# removes irrelevance from coverage report
lcov --remove ./lcov.info '*script*' '*step*' '*test*' -o ./lcov.info.pruned
genhtml -o report --branch-coverage lcov.info.pruned
