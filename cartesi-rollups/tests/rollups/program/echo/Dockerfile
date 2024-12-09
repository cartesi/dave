FROM cartesi/machine-emulator:0.18.1
USER root
RUN apt-get update && \
    apt-get install -y wget

RUN wget https://github.com/cartesi/image-kernel/releases/download/v0.20.0/linux-6.5.13-ctsi-1-v0.20.0.bin \
    -O ./linux.bin
RUN wget https://github.com/cartesi/machine-emulator-tools/releases/download/v0.16.1/rootfs-tools-v0.16.1.ext2 \
    -O ./rootfs.ext2

COPY ./gen_machine_echo.sh .
RUN chmod +x gen_machine_echo.sh
RUN ./gen_machine_echo.sh && tar -zvcf /echo-program.tar.gz echo-program
