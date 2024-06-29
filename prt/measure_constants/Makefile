LIBNAME = chronos

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

chronos.so: $(FILES)
	env $(CC) $(DLLFLAGS) $(CFLAGS) chronos.c -o chronos.so

clean:
	rm -f chronos.so
