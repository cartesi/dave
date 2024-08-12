BINDINGS_DIR := ./contract-bindings/src
BINDING_FILES = \
    leaf_tournament.rs \
    non_leaf_tournament.rs \
    non_root_tournament.rs \
    root_tournament.rs \
    shared_types.rs \
    tournament.rs
SRC_DIR := ./contracts

# Common commands
CLEAN_CMD := find . -wholename '$(BINDINGS_DIR)/*.rs' ! -name 'lib.rs' -delete
FORGE_CMD := cd $(SRC_DIR) && forge

help:
	@echo '  clean                      - clean the cache artifacts and generated files'
	@echo '  bind                       - generate Rust bindings from Solidity code'

clean:
	@$(CLEAN_CMD)
	@$(FORGE_CMD) clean

bind: clean
	@$(FORGE_CMD) bind --ethers && \
	for file in $(BINDING_FILES); do \
		cp ./out/bindings/src/$$file ../$(BINDINGS_DIR)/; \
	done

.PHONY: help bind clean
