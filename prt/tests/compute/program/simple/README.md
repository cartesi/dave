# Simple test program

## Generate program

From this directory, run the following:

```
docker build -t simple:test .
docker cp $(docker create simple:test):/simple-program.tar.gz .
```
