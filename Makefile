SHELL := /bin/bash

# Project layout
APP_NAME         ?= Illumination
PROJECT_DIR      ?= .
PROJECT          ?= $(PROJECT_DIR)/$(APP_NAME).xcodeproj
XCODEGEN_PROJECT ?= $(PROJECT_DIR)
XCODEGEN_SPEC    ?= ./project.yml
SCHEME           ?= $(APP_NAME)
CONFIGURATION    ?= Release
BUILD_DIR        ?= ./build
BUILD_DIR_STAMP  := $(BUILD_DIR)/.dir-stamp
DERIVED_DATA     := $(BUILD_DIR)/DerivedData
ARCHIVE          := $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_OPTIONS   ?= ./ExportOptions.plist
APP_BUNDLE       := $(BUILD_DIR)/$(APP_NAME).app

# Scripts
SIGNING_RESOLVER_SCRIPT := ./scripts/resolve-signing.sh

.PHONY: all release xcodegen xcodegen-check build devsigned archive export package clean

all: build
release: build

$(BUILD_DIR_STAMP):
	@mkdir -p $(BUILD_DIR)
	@touch $(BUILD_DIR_STAMP)

xcodegen:
	@echo "--> Generating Xcode project from $(XCODEGEN_SPEC)"
	@xcodegen generate --spec "$(XCODEGEN_SPEC)" --project "$(XCODEGEN_PROJECT)"
	@echo "✅ Xcode project generated at $(PROJECT)"

xcodegen-check:
	@bash ./scripts/xcodegen-check.sh

# -------- Lane A: unsigned local build (default) --------
build: xcodegen $(BUILD_DIR_STAMP)
	@echo "--> Building unsigned $(APP_NAME) (scheme=$(SCHEME), configuration=$(CONFIGURATION))"
	xcodebuild \
	  -project "$(PROJECT)" \
	  -scheme "$(SCHEME)" \
	  -configuration "$(CONFIGURATION)" \
	  -destination 'platform=macOS' \
	  -derivedDataPath "$(DERIVED_DATA)" \
	  CODE_SIGNING_ALLOWED=NO \
	  build
	@rm -rf "$(APP_BUNDLE)"
	@cp -R "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app" "$(APP_BUNDLE)"
	@echo "✅ Unsigned app available at $(APP_BUNDLE)"

# -------- Lane B: automatically signed developer build --------
devsigned: xcodegen $(BUILD_DIR_STAMP)
	@echo "--> Building with Automatic signing"
	@eval "$$($(SIGNING_RESOLVER_SCRIPT))"; \
	identity="$$SIGNING_IDENTITY"; \
	team_id="$$DEVELOPMENT_TEAM"; \
	echo "--> Using team $$team_id"; \
	xcodebuild \
	  -project "$(PROJECT)" \
	  -scheme "$(SCHEME)" \
	  -configuration "$(CONFIGURATION)" \
	  -destination 'platform=macOS' \
	  -derivedDataPath "$(DERIVED_DATA)" \
	  CODE_SIGN_STYLE=Automatic \
	  DEVELOPMENT_TEAM="$$team_id" \
	  CODE_SIGNING_ALLOWED=YES \
	  build
	@rm -rf "$(APP_BUNDLE)"
	@cp -R "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app" "$(APP_BUNDLE)"
	@codesign --verify --verbose "$(APP_BUNDLE)" || true
	@echo "✅ Dev-signed app available at $(APP_BUNDLE)"

# -------- Lane C: distribution archive (maintainers) --------
archive: xcodegen $(BUILD_DIR_STAMP)
	@echo "--> Archiving $(APP_NAME) for distribution"
	@eval "$$(REQUIRE_NONINTERACTIVE=1 ALLOW_INTERACTIVE=0 $(SIGNING_RESOLVER_SCRIPT))"; \
	identity="$$SIGNING_IDENTITY"; \
	team_id="$$DEVELOPMENT_TEAM"; \
	xcodebuild \
	  -project "$(PROJECT)" \
	  -scheme "$(SCHEME)" \
	  -configuration "$(CONFIGURATION)" \
	  -destination 'generic/platform=macOS' \
	  -archivePath "$(ARCHIVE)" \
	  CODE_SIGN_STYLE=Manual \
	  CODE_SIGN_IDENTITY="$$identity" \
	  DEVELOPMENT_TEAM="$$team_id" \
	  archive

export: archive
	@echo "--> Exporting archive using $(EXPORT_OPTIONS)"
	@if xcodebuild -exportArchive \
	  -archivePath "$(ARCHIVE)" \
	  -exportOptionsPlist "$(EXPORT_OPTIONS)" \
	  -exportPath "$(BUILD_DIR)"; then \
	  echo "✅ exportArchive succeeded"; \
	else \
	  echo "⚠️ exportArchive failed; archive remains at $(ARCHIVE)"; \
	fi

package: build
	@echo "--> Creating zip from $(APP_BUNDLE)"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME).zip"
	@echo "✅ Package available at $(BUILD_DIR)/$(APP_NAME).zip"

clean:
	@echo "--> Cleaning build artifacts..."
	@xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" clean || true
	@rm -rf "$(BUILD_DIR)"
	@echo "✅ Clean"
