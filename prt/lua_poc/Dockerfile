FROM cartesi/machine-emulator:0.18.1

USER 0
RUN apt-get -y update && \
    apt-get -y install curl gcc imagemagick make procps xxd
ENV FOUNDRY_NIGHTLY nightly-5b7e4cb3c882b28f3c32ba580de27ce7381f415a
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_NIGHTLY}/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare debootstrap machine
WORKDIR "/app/lua_poc/program"
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.8-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C "/app/lua_poc/program"

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.9-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C "/app/lua_poc/program"

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.10-rc-test/simple-program.tar.gz | \
    tar -zx -C "/app/lua_poc/program"

WORKDIR "/machine-emulator-sdk"
ADD ./machine-emulator-sdk/ .

WORKDIR "/app/contracts"
ADD ./prt/contracts/foundry.toml .
ADD ./prt/contracts/lib/ ./lib/
ADD ./prt/contracts/src/ ./src/
ADD ./prt/contracts/script/ ./script/

RUN forge --version
RUN forge build

ADD ./prt/contracts/deploy_anvil.sh .

WORKDIR "/app/lua_poc"

COPY ./prt/lua_poc/ .
RUN chmod +x compute-test-entrypoint.sh
RUN chmod +x prt_compute.lua
RUN chmod +x doom_showcase/process_doom_graphics.lua

WORKDIR "/app"
RUN mkdir -p pixels
RUN mkdir -p outputs
RUN mkdir -p machines
ENTRYPOINT ["./lua_poc/compute-test-entrypoint.sh"]
