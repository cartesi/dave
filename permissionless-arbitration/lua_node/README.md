# Dave Lua node

The Lua node is used for testing and prototyping only.

## Run example

Remember to either clone the repository with the flag `--recurse-submodules`, or run `git submodule update --recursive --init` after cloning.

You need a docker installation to run the Dave Lua node.
From the path `permissionless-arbitration/lua_node`, run the following command:

```
docker build -t dave:latest -f Dockerfile ../../ && docker run --rm dave:latest
```
