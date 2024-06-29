# RISC-V programs

## Generate programs

From this directory, run the following:

```
docker run --platform linux/amd64 -it --rm -h gen-program \
          -e USER=$(id -u -n) \
          -e GROUP=$(id -g -n) \
          -e UID=$(id -u) \
          -e GID=$(id -g) \
          -v (pwd):/home/$(id -u -n) \
          -w /home/$(id -u -n) \
          cartesi/machine-emulator:0.15.2 /bin/bash -c "./gen_machine_simple.sh"
```

Or

```
docker run --platform linux/amd64 -it --rm -h gen-program \
          -e USER=$(id -u -n) \
          -e GROUP=$(id -g -n) \
          -e UID=$(id -u) \
          -e GID=$(id -g) \
          -v (pwd):/home/$(id -u -n) \
          -w /home/$(id -u -n) \
          cartesi/machine-emulator:0.15.2 /bin/bash -c "./gen_machine_linux.sh"
```
