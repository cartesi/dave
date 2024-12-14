BINDINGS_DIR := ./contract-bindings/src/contract
SRC_DIR := ./contracts
BINDINGS_FILTER := '^[^I].+TournamentFactory|LeafTournament|RootTournament|^Tournament$$'

help:
	@echo '  clean                      - clean the generated bindings'
	@echo '  bind                       - generate Rust bindings from Solidity code'

clean:
	@rm -rf $(BINDINGS_DIR)

bind:
	@forge bind --alloy --select $(BINDINGS_FILTER) \
	--module --bindings-path $(BINDINGS_DIR) \
	--root $(SRC_DIR)

.PHONY: help bind clean
