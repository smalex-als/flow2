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
	@echo "  run        Build and launch the application"
	@echo "  restart    Stop, rebuild, and launch the application"
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

run: build
	open "$(APP)"

restart:
	$(MAKE) stop
	$(MAKE) run

stop:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true

test:
	@echo "No unit test target is configured for $(SCHEME)."

open:
	open "$(PROJECT)"

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean
