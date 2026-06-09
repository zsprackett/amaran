# Convenience wrapper around the SwiftPM build/test commands.
# Everything here is a thin alias; there are no non-Swift build dependencies.

.PHONY: build build-helper test test-core test-mesh

# Release build of the `amaran` CLI (also what `bin/amaran` builds on first run).
build:
	swift build -c release

# Build + sign the CoreBluetooth helper bundle (AmaranHelper.app), required for
# any BLE command. Honors AMARAN_CODESIGN_IDENTITY and AMARAN_BUILD_CONFIG.
build-helper:
	scripts/build-amaran-helper

# Default local regression gate: SwiftPM unit suites + native mesh vectors.
test: test-core test-mesh

# AmaranCore/AmaranCLI unit suites.
test-core:
	swift test

# Native Bluetooth Mesh crypto/vector tests (standalone swiftc build).
test-mesh:
	scripts/test-mesh
