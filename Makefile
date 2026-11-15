CONFIG ?= debug
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test build run clean release server-test sync-e2e ios-project

test:
	swift test

build:
	zsh Scripts/build-app.sh $(CONFIG)

run: build
	open dist/PasteHub.app

clean:
	swift package clean
	rm -rf dist .build

release:
	zsh Scripts/release.sh

server-test:
	cd Server && go test -race ./...

sync-e2e:
	zsh Scripts/sync-e2e.sh

ios-project:
	cd iOS && xcodegen
