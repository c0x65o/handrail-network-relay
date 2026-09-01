.PHONY: check release test

check:
	python3 -m py_compile src/handrail_network_relay.py
	bash -n scripts/*.sh
	./scripts/check-systemd-unit.sh

test:
	python3 -m unittest discover -s tests -v

release: check test
	./scripts/build-release.sh
