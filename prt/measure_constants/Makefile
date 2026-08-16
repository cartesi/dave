LUA_CFLAGS := $(shell pkg-config --cflags-only-I lua5.4)
COPT = -O2 -DNDEBUG
CWARNS = -Wall -Wextra -pedantic
CFLAGS = $(CWARNS) $(COPT) $(LUA_CFLAGS)
CC = gcc

TARGET_OS?=$(shell uname)
ifeq ($(TARGET_OS),Darwin)
DLLFLAGS=-bundle -undefined dynamic_lookup
else
DLLFLAGS=-shared -fPIC
endif

chronos.so: chronos.c
	env $(CC) $(DLLFLAGS) $(CFLAGS) chronos.c -o chronos.so

clean:
	rm -f chronos.so
