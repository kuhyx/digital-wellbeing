## Commands

- run: n/a: collection of installer and guard scripts, no single entry point
- test: `tests/run_all.sh`
- test-changed: `scripts/test_changed.sh`
- lint: `git ls-files '*.sh' ':!:vendor/*' | xargs shellcheck`
- coverage: n/a: no coverage tooling for bash suites
- coverage-gaps: n/a: no coverage report exists
