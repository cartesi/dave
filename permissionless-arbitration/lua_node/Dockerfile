FROM cartesi/machine-emulator:0.17.0

USER 0
RUN apt-get -y update && \
    apt-get -y install curl gcc imagemagick make procps xxd
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/nightly-5b7e4cb3c882b28f3c32ba580de27ce7381f415a/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare debootstrap machine
WORKDIR "/app/lua_node/program"
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.5-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C "/app/lua_node/program"

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.6-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C "/app/lua_node/program"

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.7-rc-test/simple-program.tar.gz | \
    tar -zx -C "/app/lua_node/program"

WORKDIR "/machine-emulator-sdk"
ADD ./machine-emulator-sdk/ .

WORKDIR "/app/contracts"
ADD ./permissionless-arbitration/contracts/foundry.toml .
ADD ./permissionless-arbitration/contracts/lib/ ./lib/
ADD ./permissionless-arbitration/contracts/src/ ./src/
ADD ./permissionless-arbitration/contracts/script/ ./script/

RUN forge --version
RUN forge build

ADD ./permissionless-arbitration/contracts/deploy_anvil.sh .

WORKDIR "/app/lua_node"

COPY ./permissionless-arbitration/lua_node/ .
RUN chmod +x dave-test-entrypoint.sh
RUN chmod +x self_contained_entrypoint.lua
RUN chmod +x doom_showcase/process_doom_graphics.lua

WORKDIR "/app"
RUN mkdir -p snapshots
ENTRYPOINT ["./lua_node/dave-test-entrypoint.sh"]
