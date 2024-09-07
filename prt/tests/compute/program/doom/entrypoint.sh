export RIV_CARTRIDGE=/dev/pmem1
export RIV_REPLAYLOG=/dev/pmem2
export RIV_OUTCARD=/run/outcard
export RIV_NO_YIELD=y
riv-run
cat /run/outcard > /dev/pmem3
