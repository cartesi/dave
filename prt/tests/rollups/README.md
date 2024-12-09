# PRT Rollups test

This directory contains a rollups node written in Rust.
The node test will be conducted with a Lua orchestrator script spawning an honest rollups node in the background to advance the rollups states and to defend the application. The Lua orchestrator script also spawns multiple [dishonest nodes](../../../prt/tests/compute/README.md) trying to tamper with the rollups states.

Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.
You need a docker installation to run the Dave Lua node.

## Build test image

In order to run tests in this directory, a docker image must be built to prepare the test environment.
Once the test image is built, the user can run all the tests supported by swapping the `MACHINE_PATH` env variable.

```
make create-image
```

## Run echo test

A simple [echo program](./program/echo/) is provided to test the rollups.

```
make test-echo
```