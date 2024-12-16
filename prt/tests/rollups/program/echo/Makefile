ECHO_MACHINE_PATH := "/root/program/echo-program"

help:
	@echo '  build-echo                - build echo machine image'

build-echo:
	@docker build -t echo:test .
	@docker cp $(shell docker create echo:test):/echo-program.tar.gz .

.PHONY: help build-echo
