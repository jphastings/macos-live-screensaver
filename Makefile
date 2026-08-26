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

build:
	rm -rf $(BUILD_DIR)/$(SCREENSAVER_NAME)
	mkdir -p $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/MacOS
	mkdir -p $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/Resources
	swiftc -emit-library \
		-o $(BUILD_DIR)/$(SCREENSAVER_NAME)/Contents/MacOS/LiveScreensaver \
		-module-name LiveScreensaver \
		-framework ScreenSaver \
		-framework AVFoundation \
		-framework Cocoa \
		-framework Quartz \
		screensaver.swift
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
