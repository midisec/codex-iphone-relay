PYTHON ?= python3

.PHONY: build check ios-build

build:
	bash scripts/build_mac.sh

check: build
	bash scripts/test_core.sh
	bash scripts/test_usb_recovery.sh
	bash scripts/test_api_configuration.sh
	bash scripts/test_api_sync.sh
	$(PYTHON) -m unittest discover -s Tests -p 'test_*.py'
	$(PYTHON) scripts/integration_test.py

ios-build:
	$(PYTHON) scripts/ios.py build
