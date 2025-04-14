FREEDOOM_VER=v0.2.0
KERNEL_VER=v0.19.1-riv1
RIV_VER=v0.3-rc10
LINUX_VER=linux-6.5.9-ctsi-1-$(KERNEL_VER)
TAPE=gameplay-example.rivtape

machine-image:
	@cp $(TAPE) $(TAPE).tmp && truncate -s 64K $(TAPE).tmp
	@rm -f $(TAPE).json && truncate -s 64K $(TAPE).json
	cartesi-machine \
		--ram-image=kernel.bin \
		--append-init=USER=root \
		--flash-drive=start:0x80000000000000,label:root,filename:rivos.ext2 \
		--flash-drive=start:0x90000000000000,label:cartridge,filename:freedoom.sqfs,mount:false \
		--flash-drive=start:0xa0000000000000,length:64Ki,label:tape \
		--flash-drive=start:0xb0000000000000,length:64Ki,label:outcard \
		--replace-flash-drive=start:0xa0000000000000,length:64Ki,filename:$(TAPE).tmp \
		--max-mcycle=0 \
		--store=machine-image \
		--append-entrypoint-file=entrypoint.sh
