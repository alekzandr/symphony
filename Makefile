.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix
FORMAT_FILES := \
	mix.exs \
	config/config.exs \
	lib/symphony_elixir/config.ex \
	lib/symphony_elixir/workflow.ex \
	lib/symphony_elixir/workflow_store.ex \
	lib/symphony_elixir/config/schema.ex \
	lib/symphony_elixir/codex/app_server.ex \
	test/support/test_support.exs \
	test/symphony_elixir/app_server_test.exs \
	test/symphony_elixir/core_test.exs \
	test/symphony_elixir/extensions_test.exs \
	test/symphony_elixir/workspace_and_config_test.exs

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	@tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	for file in $(FORMAT_FILES); do \
		mkdir -p "$$tmpdir/$$(dirname "$$file")"; \
		cp "$$file" "$$tmpdir/$$file"; \
	done; \
	cd "$$tmpdir" && $(MIX) format $(FORMAT_FILES); \
	for file in $(FORMAT_FILES); do \
		cp "$$tmpdir/$$file" "$$file"; \
	done

fmt-check:
	@tmpdir=$$(mktemp -d); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	for file in $(FORMAT_FILES); do \
		mkdir -p "$$tmpdir/$$(dirname "$$file")"; \
		cp "$$file" "$$tmpdir/$$file"; \
	done; \
	cd "$$tmpdir" && $(MIX) format --check-formatted $(FORMAT_FILES)

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
