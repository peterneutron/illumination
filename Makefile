SHELL := /bin/bash

# Project layout
APP_NAME        ?= Illumination
PROJECT         ?= ./Illumination.xcodeproj
SCHEME          ?= $(APP_NAME)
CONFIGURATION   ?= Release
BUILD_DIR       ?= ./build
DERIVED_DATA    := $(BUILD_DIR)/DerivedData
ARCHIVE         := $(BUILD_DIR)/$(SCHEME).xcarchive
EXPORT_OPTIONS  ?= ./ExportOptions.plist
APP_BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app

SIGNING_IDENTITY_SCRIPT := ./scripts/select_signing_identity.sh

.PHONY: all build devsigned archive export package clean

all: build

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# -------- Lane A: unsigned local build (default) --------
build: $(BUILD_DIR)
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
devsigned: $(BUILD_DIR)
	@echo "--> Building with Automatic signing"
	@identity="$$SIGNING_IDENTITY"; \
	if [[ -z "$$identity" ]]; then \
	  if [[ ! -x "$(SIGNING_IDENTITY_SCRIPT)" ]]; then \
	    echo "error: missing signing identity script at $(SIGNING_IDENTITY_SCRIPT)" >&2; \
	    exit 1; \
	  fi; \
	  identity="$$($(SIGNING_IDENTITY_SCRIPT))"; \
	fi; \
	team_id="$$(printf '%s\n' "$$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"; \
	if [[ -z "$$team_id" ]]; then \
	  echo "error: could not derive DEVELOPMENT_TEAM from signing identity '$$identity'" >&2; \
	  exit 1; \
	fi; \
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
archive: $(BUILD_DIR)
	@echo "--> Archiving $(APP_NAME) for distribution"
	@identity="$$SIGNING_IDENTITY"; \
	if [[ -z "$$identity" ]]; then \
	  if [[ ! -x "$(SIGNING_IDENTITY_SCRIPT)" ]]; then \
	    echo "error: missing signing identity script at $(SIGNING_IDENTITY_SCRIPT)" >&2; \
	    exit 1; \
	  fi; \
	  identity="$$($(SIGNING_IDENTITY_SCRIPT))"; \
	fi; \
	team_id="$$(printf '%s\n' "$$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"; \
	if [[ -z "$$team_id" ]]; then \
	  echo "error: could not derive DEVELOPMENT_TEAM from signing identity '$$identity'" >&2; \
	  exit 1; \
	fi; \
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
