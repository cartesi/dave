# Dave Compute Node

## Build test image

```
docker build -t cartesi/dave-compute:test -f Dockerfile.compute.test ../
```

## Run simple test

Requires image built from [previous section]().

```
docker run --rm --env MACHINE_PATH="/root/permissionless-arbitration/lua_node/program/simple-program" cartesi/dave-compute:test
```

## Run stress test

Requires image built from [previous section]().

```
docker run --rm --env MACHINE_PATH="/root/permissionless-arbitration/lua_node/program/debootstrap-machine-sparsed" cartesi/dave-compute:test
```
