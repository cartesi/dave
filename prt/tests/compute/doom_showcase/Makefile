LUADIR=$(shell pkg-config --cflags-only-I lua)
COPT = -O2
CWARNS = -Wall -Wextra -pedantic
CFLAGS = $(CWARNS) $(COPT)

UNAME_S := $(shell uname -s)

# macOS-specific settings
ifeq ($(UNAME_S), Darwin)
DLLFLAGS=-bundle -undefined dynamic_lookup
else
DLLFLAGS=-shared -fPIC
endif

# Target
all: playpal2rgb

# Build shared library
playpal2rgb_lua.so: playpal2rgb_lua.c
	$(CC) $(DLLFLAGS) $(CFLAGS) $(LUADIR) -o $@ $^

playpal2rgb: main.c
	$(CC) $(CFLAGS) -o $@ $^

.PHONY: clean
clean:
	rm -f playpal2rgb playpal2rgb_lua.so
