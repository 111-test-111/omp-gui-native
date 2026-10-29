.DEFAULT_GOAL := build
.NOTPARALLEL:

.PHONY: build run clean verify verify-plan help

TIER ?= functional
VERIFY_OPTIONS = --tier "$(TIER)" $(if $(OMP),--omp "$(OMP)") $(if $(PAPER),--paper "$(PAPER)")

build: ## Incrementally build the local OMP GUI Dev app.
	@bash scripts/develop.sh build

run: ## Build, then open the local Dev app.
	@bash scripts/develop.sh run

clean: ## Remove all repository build products and caches.
	@bash scripts/develop.sh clean

verify: ## List or run explicitly selected checks from one tier, once each.
	@PYTHONDONTWRITEBYTECODE=1 python3 tests/run.py $(VERIFY_OPTIONS) $(AREAS)

verify-plan: ## Show the selected checks without executing them.
	@PYTHONDONTWRITEBYTECODE=1 python3 tests/run.py --dry-run $(VERIFY_OPTIONS) $(AREAS)

help: ## Show the development commands.
	@printf '%s\n' 'make build  Compile OMP GUI Dev without installing or launching.' 'make run    Build and open OMP GUI Dev.' 'make clean  Delete build products and caches; keep app data.' 'make verify  List functional areas without running checks.' 'make verify AREAS="rpc"  Run only the selected checks.' 'make verify-plan TIER=native AREAS="questions"  Inspect requirements and dependencies.' 'make verify TIER=static AREAS="harness syntax"  Validate test tooling.' 'See docs/verification.md for native, benchmark and manual acceptance rules.'
