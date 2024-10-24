FROM cartesi/machine-emulator:0.18.1

USER 0
RUN apt-get -y update && \
    apt-get -y install curl gcc imagemagick make procps xxd pkg-config
ENV FOUNDRY_NIGHTLY nightly-5b7e4cb3c882b28f3c32ba580de27ce7381f415a
RUN curl -sSL https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_NIGHTLY}/foundry_nightly_linux_$(dpkg --print-architecture).tar.gz | \
    tar -zx -C /usr/local/bin

# prepare debootstrap machine
WORKDIR "/app/tests/compute/program"
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.8-rc-test/debootstrap-machine-sparsed.tar.gz | \
    tar -zx -C "/app/tests/compute/program"

# prepare doom-showcase machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.9-rc-test/doom-compute-machine.tar.gz | \
    tar -zx -C "/app/tests/compute/program"

# prepare simple machine
RUN curl -sSL https://github.com/cartesi/dave/releases/download/v0.0.10-rc-test/simple-program.tar.gz | \
    tar -zx -C "/app/tests/compute/program"

WORKDIR "/machine/step"
ADD ./machine/step/ .

WORKDIR "/app/contracts"
ADD ./prt/contracts/foundry.toml .
ADD ./prt/contracts/lib/ ./lib/
ADD ./prt/contracts/src/ ./src/
ADD ./prt/contracts/script/ ./script/

RUN forge --version
RUN forge build

ADD ./prt/contracts/deploy_anvil.sh .

WORKDIR "/app/client-lua"
COPY ./prt/client-lua/ .

WORKDIR "/app/tests/compute"
COPY ./prt/tests/compute/ .
RUN chmod +x compute-test-entrypoint.sh
RUN chmod +x prt_compute.lua
RUN chmod +x doom_showcase/process_doom_graphics.lua

WORKDIR "/app"
RUN mkdir -p pixels
RUN mkdir -p outputs
RUN mkdir -p /compute_data/0xa16E02E87b7454126E5E10d957A927A7F5B5d2be

WORKDIR "/app/tests/compute"
ENTRYPOINT ["./compute-test-entrypoint.sh"]
