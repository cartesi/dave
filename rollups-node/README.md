# Dave Rollups Node

## Build test image

```
docker build -t cartesi/rollups-node:test ../ -f Dockerfile.test
```

## Run rollups tests

The `machine-runner` test requires a working cartesi-machine instance.
The easiest way to create cartesi-machine environment is to run it from a [docker image](#build-test-image).

```
docker run --rm --env INFURA_KEY="" cartesi/rollups-node:test
```
