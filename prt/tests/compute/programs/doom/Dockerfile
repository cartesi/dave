FROM cartesi/machine-emulator:0.19.0-alpha3
USER root
ENV FREEDOOM_VER=v0.2.0
ENV KERNEL_VER=v0.19.1-riv1
ENV RIV_VER=v0.3-rc10
ENV LINUX_VER=linux-6.5.9-ctsi-1-${KERNEL_VER}

WORKDIR /root
RUN apt-get update && \
    apt-get install -y make wget
RUN wget -O rivos.ext2 https://github.com/rives-io/riv/releases/download/${RIV_VER}/rivos.ext2
RUN wget -O kernel.bin https://github.com/rives-io/kernel/releases/download/${KERNEL_VER}/${LINUX_VER}.bin
RUN wget -O freedoom.sqfs https://github.com/rives-io/cartridge-freedoom/releases/download/${FREEDOOM_VER}/freedoom.sqfs

COPY ./Makefile .
COPY ./gameplay-example.rivtape .
COPY ./entrypoint.sh .
RUN make machine-image
