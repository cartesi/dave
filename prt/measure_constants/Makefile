

LUADIR=$(shell pkg-config --cflags-only-I lua)
COPT = -O2 -DNDEBUG
CWARNS = -Wall -Wextra -pedantic
CFLAGS = $(CWARNS) $(COPT) $(LUADIR)
CC = gcc

TARGET_OS?=$(shell uname)
ifeq ($(TARGET_OS),Darwin)
DLLFLAGS=-bundle -undefined dynamic_lookup
else
DLLFLAGS=-shared -fPIC
endif

create-image:
	@docker build -t cartesi/measure_script .

measure-simple: create-image
	@docker run --rm \
		--env MACHINE_PATH=simple-program \
		cartesi/measure_script:latest

measure-stress: create-image
	@docker run --rm \
		--env MACHINE_PATH=debootstrap-machine-sparsed \
		cartesi/measure_script:latest

measure-doom: create-image
	@docker run --rm \
		--env MACHINE_PATH=doom-compute-machine \
		cartesi/measure_script:latest

chronos.so: $(FILES)
	env $(CC) $(DLLFLAGS) $(CFLAGS) chronos.c -o chronos.so

clean:
	rm -f chronos.so
