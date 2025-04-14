# Doom test program

## Generate program

From this directory, run the following:

```
docker build -t doom:test .
docker cp $(docker create doom:test):/root/machine-image .
```
