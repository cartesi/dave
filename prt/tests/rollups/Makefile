ECHO_MACHINE_PATH := "/root/program/echo-program"

help:
	@echo '  create-image              - create `prt-rollups:test` docker image'
	@echo '  test-echo                 - run PRT rollups echo test'

create-image:
	@docker build -t cartesi/prt-rollups:test -f Dockerfile ../../../

test-echo: create-image
	@docker run --rm --name rollups-echo-test \
		--env MACHINE_PATH=$(ECHO_MACHINE_PATH) \
		cartesi/prt-rollups:test




.PHONY: help create-image test-echo
