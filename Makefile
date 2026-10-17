PROJECT := Flow2.xcodeproj
SCHEME := Flow2
APP_NAME := Flow2
CONFIGURATION ?= Debug
DERIVED_DATA := $(CURDIR)/.deriveddata
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/$(APP_NAME).app
DIST_DIR := $(CURDIR)/dist
DIST_ARCHIVE := $(DIST_DIR)/$(APP_NAME).zip

.DEFAULT_GOAL := help

.PHONY: help build release dist run restart stop test open clean

help:
	@echo "Usage: make <target>"
	@echo
	@echo "  help       Show available commands"
	@echo "  build      Build the application"
	@echo "  release    Build the optimized Release application"
	@echo "  dist       Create a distributable ZIP in dist/"
	@echo "  run        Stop the running app, rebuild, and launch it"
	@echo "  restart    Alias for run"
	@echo "  stop       Quit the running application"
	@echo "  test       Run the unit tests"
	@echo "  open       Open the project in Xcode"
	@echo "  clean      Remove Xcode build products"

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

release:
	$(MAKE) build CONFIGURATION=Release

dist: release
	mkdir -p "$(DIST_DIR)"
	ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_APP)" "$(DIST_ARCHIVE)"
	@echo "Created $(DIST_ARCHIVE)"

# Stopping first is not optional. A rebuild replaces the binary under any running instance,
# whose code then stops matching the file on disk; macOS denies that process keychain access,
# and the app reports "The user name or passphrase you entered is not correct" (-25293).
# Without it `open` also just foregrounds the old build, so the new one is never seen.
run:
	$(MAKE) stop
	$(MAKE) build
	open "$(APP)"

restart: run

# `pkill` only asks. Returning before the process is gone lets a following `open` land on the
# dying instance, which fails with LaunchServices error -600, so wait for it to actually exit.
# Scope both commands to this user; another user's instance cannot be stopped by us.
stop:
	@pkill -u "$$(id -u)" -x "$(APP_NAME)" 2>/dev/null || true
	@i=0; while pgrep -u "$$(id -u)" -x "$(APP_NAME)" >/dev/null; do \
		i=$$((i + 1)); \
		[ $$i -eq 50 ] && pkill -9 -u "$$(id -u)" -x "$(APP_NAME)" 2>/dev/null; \
		if [ $$i -gt 80 ]; then echo "$(APP_NAME) will not exit" >&2; exit 1; fi; \
		sleep 0.1; \
	done

test:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA)

open:
	open "$(PROJECT)"

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean
