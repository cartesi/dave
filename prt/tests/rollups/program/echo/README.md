# Simple echo program

## Generate program

From this directory, run the following:

```
docker build -t echo:test .
docker cp $(docker create echo:test):/echo-program.tar.gz .
```
