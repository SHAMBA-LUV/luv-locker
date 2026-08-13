.PHONY: build test audit testmd gas sizes cov fork deploy fmt

build:
	forge build

test:
	forge test -vvv

# The properties that must never regress: no owner path to principal, LUV can never
# be swept, principal always fully backed, measured deltas under transfer fees.
audit:
	forge test --match-test 'test_A1_|LuvCanNeverBeSwept|MeasuredDelta' -vvv
	forge test --match-test 'Fuzz_Balance|HarvestNeverPaysOutOfPrincipal' -vvv
	forge test --match-test 'BlockLock|Relocks|Compounding' -vvv

# Verify test.md's green checkmarks against a live run. Fails on drift.
testmd:
	python3 ../scripts/check_test_md.py $(notdir $(CURDIR))

gas:
	forge test --gas-report

sizes:
	forge build --sizes

cov:
	forge coverage --report lcov

fork:
	forge script script/deploy.s.sol:Deploy --rpc-url mainnet

deploy:
	forge script script/deploy.s.sol:Deploy --rpc-url mainnet --broadcast --verify --slow

fmt:
	forge fmt

fork-test:
	FOUNDRY_PROFILE=fork FORK_TEST=1 forge test --match-path test/luv_locker_fork.t.sol -vv
