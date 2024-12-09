#!/bin/bash
cartesi-machine --ram-image=./linux.bin \
  --flash-drive=label:root,filename:./rootfs.ext2 \
  --no-rollback --store=./echo-program \
  -- "ioctl-echo-loop --vouchers=1 --notices=1 --reports=1 --verbose=1"
