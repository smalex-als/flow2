PROJECT := Flow2.xcodeproj
SCHEME := Flow2
CONFIGURATION ?= Debug
DERIVED_DATA := $(CURDIR)/.deriveddata
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Flow2.app

.PHONY: build run clean

build:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		build

run: build
	open "$(APP)"

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-derivedDataPath $(DERIVED_DATA) \
		clean
