CONFIG ?= debug
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: test build run clean release

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
