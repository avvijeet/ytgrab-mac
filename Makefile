.PHONY: build test lint format app e2e

build:
	swift build -c release

test:
	swift test

# Integration tests hit the network; run only when explicitly requested.
e2e:
	YTGRAB_E2E=1 swift test --filter IntegrationTests

lint:
	swiftlint lint --strict
	xcrun swift-format lint --recursive Sources Tests

format:
	xcrun swift-format format --in-place --recursive Sources Tests

app:
	./build.sh

install:
	./build.sh
	ditto YTGrab.app /Applications/YTGrab.app
