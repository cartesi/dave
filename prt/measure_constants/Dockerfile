FROM cartesi/machine-emulator:0.18.1
USER root

RUN apt-get update && \
    apt-get install -y procps curl git xxd build-essential pkg-config liblua5.4-dev

WORKDIR "/app"

# prepare debootstrap machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.5-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C "/app"

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.6-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C "/app"

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.7-rc-test/simple-program.tar.gz | \
    tar -zx -C "/app"

COPY chronos.c .
COPY Makefile .
RUN make

COPY measure.lua .
RUN chmod +x measure.lua

ENTRYPOINT ["lua", "/app/measure.lua"]
