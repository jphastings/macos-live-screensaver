.PHONY: build install clean uninstall start verify lint format

SCREENSAVER_NAME = LiveScreensaver.saver
INSTALL_DIR = $(HOME)/Library/Screen\ Savers
BUILD_DIR = build

# Marketing version, e.g. 1.2.0. Release CI passes the git tag with its
# leading "v" stripped; a local build gets 0.0.0 so it is obviously not a
# release.
VERSION ?= 0.0.0
# Monotonic build number. Release CI passes the run number.
BUILD_NUMBER ?= 0

# Architectures to build and merge into the shipped binary. Without an explicit
# -target, swiftc emits a single slice for whatever the build machine happens to
# be -- which on CI means Apple Silicon only, silently excluding every Intel Mac.
ARCHS ?= arm64 x86_64
# Minimum macOS. Must stay in step with LSMinimumSystemVersion in Info.plist.
# Without this the deployment target is whatever SDK the build machine has, so a
# runner image upgrade would raise the minimum OS without anyone noticing.
MACOS_MIN ?= 13.0

SWIFT_FLAGS = -emit-library -module-name LiveScreensaver \
	-framework ScreenSaver -framework AVFoundation \
	-framework Cocoa -framework Quartz
SOURCES = screensaver.swift

build:
	rm -rf $(BUILD_DIR)/$(SCREENSAVER_NAME) $(BUILD_DIR)/slices
	mkdir -p $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/MacOS
	mkdir -p $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Resources
	mkdir -p $(BUILD_DIR)/slices
	@set -e; for arch in $(ARCHS); do \
		echo "Compiling $$arch slice (macOS $(MACOS_MIN) minimum)"; \
		swiftc $(SWIFT_FLAGS) \
			-target $$arch-apple-macos$(MACOS_MIN) \
			-o $(BUILD_DIR)/slices/LiveScreensaver-$$arch \
			$(SOURCES); \
	done
	lipo -create -output \
		$(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/MacOS/LiveScreensaver \
		$(foreach arch,$(ARCHS),$(BUILD_DIR)/slices/LiveScreensaver-$(arch))
	rm -rf $(BUILD_DIR)/slices
	cp Info.plist $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" \
		$(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" \
		$(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Info.plist
	qlmanage -t -s 267 -o $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Resources/ thumbnail.svg
	mv $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Resources/thumbnail.svg.png $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Resources/thumbnail.png
	codesign --force --deep --sign - $(BUILD_DIR)/$(SCREENSAVER_NAME)

install: build
	cp -r $(BUILD_DIR)/$(SCREENSAVER_NAME) $(INSTALL_DIR)/

# Assert the built bundle actually contains everything a .saver needs, so a
# silently-broken build fails here rather than on a user's machine.
verify:
	@set -e; \
	bundle="$(BUILD_DIR)/$(SCREENSAVER_NAME)"; \
	for f in "Contents/MacOS/LiveScreensaver" "Contents/Info.plist" "Contents/Resources/thumbnail.png"; do \
		test -f "$$bundle/$$f" || { echo "missing: $$f"; exit 1; }; \
	done; \
	plutil -lint "$$bundle/Contents/Info.plist"; \
	test "$$(plutil -extract NSPrincipalClass raw "$$bundle/Contents/Info.plist")" = "LiveScreensaverView" \
		|| { echo "NSPrincipalClass is not LiveScreensaverView"; exit 1; }; \
	test "$$(plutil -extract CFBundleShortVersionString raw "$$bundle/Contents/Info.plist")" = "$(VERSION)" \
		|| { echo "version was not stamped into Info.plist"; exit 1; }; \
	test "$$(plutil -extract LSMinimumSystemVersion raw "$$bundle/Contents/Info.plist")" = "$(MACOS_MIN)" \
		|| { echo "LSMinimumSystemVersion does not match MACOS_MIN ($(MACOS_MIN))"; exit 1; }; \
	for arch in $(ARCHS); do \
		lipo -archs "$$bundle/Contents/MacOS/LiveScreensaver" | grep -qw "$$arch" \
			|| { echo "missing architecture: $$arch"; exit 1; }; \
	done; \
	echo "Architectures: $$(lipo -archs "$$bundle/Contents/MacOS/LiveScreensaver")"; \
	codesign --verify --verbose "$$bundle"; \
	echo "Bundle verified"

lint:
	swift-format lint --strict --recursive .

format:
	swift-format format --in-place --recursive .

clean:
	rm -rf $(BUILD_DIR)

uninstall:
	rm -rf $(INSTALL_DIR)/$(SCREENSAVER_NAME)

start:
	open /System/Library/CoreServices/ScreenSaverEngine.app
