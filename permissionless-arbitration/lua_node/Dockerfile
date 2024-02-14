FROM cartesi/machine-emulator:0.15.2

USER 0
RUN apt-get -y update; apt-get -y install curl git; apt-get install -y procps xxd
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/nightly/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

WORKDIR "/machine-emulator-sdk"
ADD ./machine-emulator-sdk/ .

WORKDIR "/app/contracts"
ADD ./permissionless-arbitration/contracts/foundry.toml .
ADD ./permissionless-arbitration/contracts/lib/ ./lib/
ADD ./permissionless-arbitration/contracts/src/ ./src/

RUN forge --version
RUN forge build

ADD ./permissionless-arbitration/contracts/deploy_anvil.sh .

WORKDIR "/app/lua_node"

COPY ./permissionless-arbitration/lua_node/ .
RUN chmod +x multiplayers_entrypoint.lua
WORKDIR "/app/lua_node/program"
RUN ./gen_machine_simple.sh

WORKDIR "/app"
ENTRYPOINT ["./lua_node/multiplayers_entrypoint.lua"]
