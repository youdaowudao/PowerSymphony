.PHONY: help all setup deps build fmt fmt-check lint test coverage coverage-policy ci dialyzer e2e

MIX ?= mix
CI_TARGETS := setup build fmt-check lint coverage coverage-policy dialyzer

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, coverage-policy, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover --export-coverage policy

coverage-policy:
	@if [ "$${COVERAGE_POLICY_BASE_REF_MODE:-enforce}" = "skip_without_base" ]; then \
		$(MIX) coverage.policy.check --cover-path cover --base-ref-mode skip_without_base; \
	else \
		test -n "$${COVERAGE_POLICY_BASE_REF}" || { echo "COVERAGE_POLICY_BASE_REF is required when COVERAGE_POLICY_BASE_REF_MODE=enforce"; exit 1; }; \
		$(MIX) coverage.policy.check --cover-path cover --base-ref "$${COVERAGE_POLICY_BASE_REF}" --base-ref-mode enforce; \
	fi

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	@status=0; \
	for target in $(CI_TARGETS); do \
		echo "[RUN] $$target"; \
		if $(MAKE) $$target; then \
			echo "[PASS] $$target"; \
		else \
			echo "[FAIL] $$target"; \
			status=1; \
		fi; \
	done; \
	exit $$status

all: ci
