FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS genext2fs-build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y git
RUN git clone https://github.com/cartesi/genext2fs /genext2fs && cd /genext2fs && git checkout v1.5.2 && ./make-debian

FROM ubuntu:jammy@sha256:b060fffe8e1561c9c3e6dea6db487b900100fc26830b9ea2ec966c151ab4c020 AS build
RUN apt-get update && apt-get install -y ca-certificates
RUN printf "deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy main restricted universe multiverse\ndeb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20231201T000000Z jammy-updates main restricted universe multiverse\n" > /etc/apt/sources.list
RUN apt-get update && apt-get install -y debootstrap patch libarchive13 e2tools
ENV TZ=UTC
ENV LC_ALL=C
ENV LANG=C.UTF-8
ENV LC_CTYPE=C.UTF-8
ENV SOURCE_DATE_EPOCH=1695938400

COPY --from=genext2fs-build /genext2fs/genext2fs.deb /genext2fs.deb
RUN dpkg -i /genext2fs.deb
RUN debootstrap --include=wget --foreign --arch riscv64 jammy /replicate/release https://snapshot.ubuntu.com/ubuntu/20231201T000000Z
RUN rm -rf /replicate/release/debootstrap/debootstrap.log
RUN touch /replicate/release/debootstrap/debootstrap.log
RUN echo -n "ubuntu" > /replicate/release/etc/hostname
COPY bootstrap /replicate/release/debootstrap/bootstrap
COPY copy /replicate/release/debootstrap/copy
RUN chmod 755 /replicate/release/debootstrap/bootstrap
RUN chmod 755 /replicate/release/debootstrap/copy
RUN echo "nameserver 127.0.0.1" > /replicate/release/etc/resolv.conf
RUN rm -df /replicate/release/proc
RUN mkdir -p /replicate/release/proc
RUN chmod 555 /replicate/release/proc
COPY additional /replicate/release/sbin/install-from-mtdblock1
RUN chmod 755 /replicate/release/sbin/install-from-mtdblock1

RUN find "/replicate/release" \
    -newermt "@1695938400" \
    -exec touch --no-dereference --date="@1695938400" '{}' +
RUN tar --sort=name -C /replicate/release -vcf - . > /replicate/release.tar
RUN HOSTNAME=linux SOURCE_DATE_EPOCH=1695938400 genext2fs -z -v -v -f -a /replicate/release.tar -B 4096 /replicate/source.ext2 2>&1 > /tool-image.gen
RUN ls -al /replicate/source.ext2
RUN rm -rf /replicate/release /replicate/release.tar

COPY --from=cartesi/linux-kernel:0.20.0 /opt/riscv/kernel/artifacts/linux-6.5.13-ctsi-1-v0.20.0.bin /usr/share/cartesi-machine/images/linux.bin
#20231201T000000Z
FROM cartesi/machine-emulator:0.19.0-alpha3 AS cartesi-base
COPY --from=build /replicate/source.ext2 /source.ext2
COPY --from=build /usr/share/cartesi-machine/images /usr/share/cartesi-machine/images
USER root

FROM cartesi-base AS debootstrap-image
RUN truncate -s 2G /image.ext2
# run copy
RUN cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/debootstrap/copy" --flash-drive=label:root,filename:/source.ext2 --flash-drive=label:dest,filename:/image.ext2,shared --ram-length=2Gi --uarch-ram-image="/usr/share/cartesi-machine/uarch/uarch-ram.bin" || true
# actually debootstrap
RUN cartesi-machine --skip-root-hash-check --append-bootargs="loglevel=8 init=/debootstrap/bootstrap" --flash-drive=label:root,filename:/image.ext2 --ram-length=2Gi --max-mcycle=0 --store=debootstrap-machine --uarch-ram-image="/usr/share/cartesi-machine/uarch/uarch-ram.bin" && \
    cp -v --sparse=always -r debootstrap-machine machine-image
