APP := build/RetroTerm.app

.PHONY: build debug run install test icon dmg clean

# Release build packaged as build/RetroTerm.app, ad-hoc signed unless SIGN_IDENTITY is set.
build:
	@./Scripts/build-app.sh release
	@echo "Built $(APP) ($$(du -sh $(APP) | cut -f1))"

debug:
	@./Scripts/build-app.sh debug

run: build
	@pkill -x RetroTerm || true
	@open $(APP)

install: build
	@pkill -x RetroTerm || true
	@rm -rf /Applications/RetroTerm.app
	@cp -R $(APP) /Applications/
	@open /Applications/RetroTerm.app
	@echo "Installed /Applications/RetroTerm.app"

test:
	@swift test

icon:
	@swift Scripts/make-icon.swift
	@iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

# Notarised DMG for distribution; needs SIGN_IDENTITY and a notarytool keychain profile. See README › Publishing.
dmg:
	@./Scripts/notarize.sh

clean:
	@rm -rf build .build
