SIMPLE_MACHINE_PATH := "/app/tests/compute/program/simple-program"
STRESS_MACHINE_PATH := "/app/tests/compute/program/debootstrap-machine-sparsed"
DOOM_MACHINE_PATH := "/app/tests/compute/program/doom-compute-machine"

LUA_NODE ?= "true"

help:
	@echo '  clean-graphics            - deletes doom graphics'
	@echo '  create-image              - create `prt-compute:lua` docker image'
	@echo '  test-simple               - run PRT simple test'
	@echo '  test-stress               - run PRT stress test'
	@echo '  test-doom                 - run PRT Doom test'
	@echo '  test-doom-with-graphics   - run PRT Doom test, saving graphics'

create-image:
	@docker build -t cartesi/prt-compute:lua -f Dockerfile ../../../

test-simple: create-image
	@docker run --rm \
		--env MACHINE_PATH=$(SIMPLE_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:lua

test-stress: create-image
	@docker run --rm \
		--env MACHINE_PATH=$(STRESS_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:lua

test-doom: create-image
	@docker run --rm \
		--env MACHINE_PATH=$(DOOM_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		cartesi/prt-compute:lua

create-doom-dirs:
	@mkdir -p pixels
	@mkdir -p outputs

clean-graphics:
	@rm -r pixels outputs

test-doom-with-graphics: create-image create-doom-dirs
	@docker run --rm \
		--env MACHINE_PATH=$(DOOM_MACHINE_PATH) \
		--env LUA_NODE=$(LUA_NODE) \
		--mount type=bind,source="$(shell pwd)/pixels",target=/app/pixels \
		--mount type=bind,source="$(shell pwd)/outputs",target=/app/outputs \
		cartesi/prt-compute:lua extra_data




.PHONY: help create-image test-simple test-stress test-doom create-doom-dirs test-doom-with-graphics
