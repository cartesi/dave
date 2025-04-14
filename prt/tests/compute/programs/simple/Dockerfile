FROM cartesi/machine-emulator:0.19.0-alpha3
USER root 

COPY ./bins ./bins
RUN cartesi-machine \
    --no-root-flash-drive \
    --ram-image="./bins/rv64ui-p-addi.bin" \
    --uarch-ram-image="/usr/share/cartesi-machine/uarch/uarch-ram.bin" \
    --max-mcycle=0 \
    --store="machine-image"
