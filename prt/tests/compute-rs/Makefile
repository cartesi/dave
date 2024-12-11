SIMPLE_MACHINE_PATH := "/root/program/simple-program"
STRESS_MACHINE_PATH := "/root/program/debootstrap-machine-sparsed"
DOOM_MACHINE_PATH := "/root/program/doom-compute-machine"

LUA_NODE ?= "false"

help:
	@echo '  clean-graphics            - deletes doom graphics'
	@echo '  create-image              - create `prt-compute:rs` docker image'
	@echo '  test-simple               - run PRT simple test'
	@echo '  test-stress               - run PRT stress test'
	@echo '  test-doom                 - run PRT Doom test'
	@echo '  test-doom-with-graphics   - run PRT Doom test, saving graphics'

create-image:
	@docker build -t cartesi/prt-compute:rs -f Dockerfile ../../../

test-simple: create-image
	@docker run --rm --name prt-compute-test-simple-rs \
		--env MACHINE_PATH=$(SIMPLE_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:rs

test-stress: create-image
	@docker run --rm --name prt-compute-test-stress-rs \
		--env MACHINE_PATH=$(STRESS_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:rs

test-doom: create-image
	@docker run --rm --name prt-compute-test-doom-rs \
		--env MACHINE_PATH=$(DOOM_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:rs




.PHONY: help create-image test-simple test-stress test-doom
