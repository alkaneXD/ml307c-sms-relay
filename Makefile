# SMS Relay — SMS ↔ Telegram bridge for ML307C and Air780EPM USB modems (macOS menu bar app)
#
#   make build     compile (release, arm64, whole-module optimised)
#   make app       build + wrap into "build/SMS Relay.app" (stripped, ad-hoc signed)
#   make dmg       build app + package build/SMS-Relay-<version>-arm64.dmg
#   make run       build app and launch it
#   make install   copy the app to /Applications
#   make debug     run the raw debug binary in the foreground (AT trace on stderr)
#   make icon      regenerate Resources/AppIcon.icns
#   make clean     remove build artifacts
#
# Set CODESIGN_IDENTITY="Developer ID Application: …" to sign with a real certificate.

ARCH ?= arm64
APP = build/SMS Relay.app
RELEASE_FLAGS = -c release --arch $(ARCH) \
	-Xswiftc -O -Xswiftc -wmo \
	-Xlinker -dead_strip

.PHONY: build app dmg run install debug icon clean

build:
	swift build $(RELEASE_FLAGS)

app: build
	Scripts/bundle.sh release $(ARCH)

dmg: build
	Scripts/make-dmg.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/SMS Relay.app" "/Applications/ML307C SMS Relay.app"
	cp -R "$(APP)" "/Applications/SMS Relay.app"
	@echo "installed /Applications/SMS Relay.app"

debug:
	swift build
	.build/debug/SMSRelay

icon:
	swift Scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build
