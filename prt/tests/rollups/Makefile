ECHO_MACHINE_PATH := "/root/program/echo-program"

help:
	@echo '  build-echo                - build echo machine image'
	@echo '  create-image              - create `prt-rollups:test` docker image'
	@echo '  test-echo                 - run PRT rollups echo test'

build-echo:
	$(MAKE) -C program/echo build-echo

create-image: build-echo
	@docker build -t cartesi/prt-rollups:test -f Dockerfile ../../../

test-echo: create-image
	@docker run --rm --name prt-rollups-test-echo \
		--env MACHINE_PATH=$(ECHO_MACHINE_PATH) \
		cartesi/prt-rollups:test



.PHONY: help build-echo create-image test-echo
