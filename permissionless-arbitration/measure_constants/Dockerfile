FROM cartesi/machine-emulator:0.16.0
USER root

RUN apt-get update && \
    apt-get install -y procps curl git xxd build-essential pkg-config liblua5.4-dev

WORKDIR "/app"

# RUN curl -sSL https://web3.link/debootstrap-machine-sparsed.tar.gz | \
#     tar -zx

COPY program/debootstrap-machine-sparsed.tar.gz .
RUN tar -zxf debootstrap-machine-sparsed.tar.gz

COPY chronos.c .
COPY Makefile .
RUN make

COPY measure.lua .
RUN chmod +x measure.lua

ENTRYPOINT ["lua", "/app/measure.lua"]
