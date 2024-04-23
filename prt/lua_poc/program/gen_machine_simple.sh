#!/bin/bash
cartesi-machine \
  --no-root-flash-drive \
  --ram-image="./bins/rv64ui-p-addi.bin" \
  --uarch-ram-image="/usr/share/cartesi-machine/uarch/uarch-ram.bin" \
  --max-mcycle=0 \
  --store="simple-program"
