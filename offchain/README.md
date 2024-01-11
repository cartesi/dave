# Dave Compute Node

## Run example

```
docker build -t cartesi/dave-compute:dev -f Dockerfile.compute ../ && docker run --rm --env MACHINE_PATH="/root/permissionless-arbitration/lua_node/program/simple-program" cartesi/dave-compute:dev
```

## Run debootstraps

```
docker build -t cartesi/dave-compute-debootstrap:dev -f Dockerfile.compute.debootstrap ../ && docker run --rm --env MACHINE_PATH="/root/permissionless-arbitration/lua_node/program/debootstrap-machine-sparsed" cartesi/dave-compute-debootstrap:dev
```
