PROJECT := Illumination.xcodeproj
SCHEME  := Release
CONFIG  := Release

BUILD_DIR      := build
ARCHIVE_PATH   := $(BUILD_DIR)/Illumination.xcarchive
DERIVED_DATA   := $(BUILD_DIR)/DerivedData
EXPORT_OPTS    := ExportOptions.plist
EXPORT_PATH    := $(BUILD_DIR)

.PHONY: all archive export clean

all: archive export

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

archive: $(BUILD_DIR)
	@echo "Archiving (signed if configured) -> $(ARCHIVE_PATH)"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-archivePath $(ARCHIVE_PATH) \
		archive
	@echo "Archive available at: $(ARCHIVE_PATH)"

export: archive
	@echo "Exporting archive -> $(EXPORT_PATH) using $(EXPORT_OPTS)"
	#@rm -rf "$(EXPORT_PATH)" && mkdir -p "$(EXPORT_PATH)"
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist $(EXPORT_OPTS) \
		-exportPath $(EXPORT_PATH)
	@echo "Export completed at: $(EXPORT_PATH)"

clean:
	@echo "Cleaning build artifacts"
	@rm -rf "$(BUILD_DIR)"
