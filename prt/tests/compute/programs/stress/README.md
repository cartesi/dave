# Stress test program

## Generate program

From this directory, run the following:

```
docker build -t debootstrap:test .
docker cp $(docker create debootstrap:test):/opt/cartesi/machine-image .
```
