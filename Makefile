APP_NAME    := Hotch
BUNDLE_ID   := com.hojaejung.hotch
VERSION     := 2.2.0
AUTHOR      := Hojae Jung
EMAIL       := hello@hotherside.com
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
BIN         := .build/release/$(APP_NAME)
# Cross-compiled slice for Intel Macs. SwiftPM cannot do a real universal build
# without full Xcode (it needs xcbuild), so the two slices are built separately
# and joined with lipo.
BIN_X86     := .build-x86/release/$(APP_NAME)
# Backpack mode helper: a root LaunchDaemon that ships inside the bundle and is
# registered at runtime with SMAppService. It is a second executable target in
# Package.swift, so the same two `swift build` runs produce both slices.
HELPER_NAME    := HotchBackpackHelper
HELPER_ID      := com.hojaejung.hotch.backpack
HELPER_PLIST   := Support/com.hojaejung.hotch.backpack.plist
HELPER_BIN     := .build/release/$(HELPER_NAME)
HELPER_BIN_X86 := .build-x86/release/$(HELPER_NAME)
DIST_DIR    := $(BUILD_DIR)/dist
ZIP         := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip
DMG         := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
# Read-write scratch image. The Finder layout lives in the volume's .DS_Store,
# which only a writable image can accept, so the shipped UDZO is converted from
# this one rather than created directly.
DMG_RW      := $(BUILD_DIR)/$(APP_NAME)-rw.dmg
STAGE       := $(BUILD_DIR)/dmg-stage
VOL_NAME    := $(APP_NAME) $(VERSION)

# Disk image window geometry. Must match Views/InstallerArt.swift, which prints
# these values when it renders the background; `make dmg` checks that they agree
# rather than trusting two copies to stay in step.
DMG_WIN_W   := 660
DMG_WIN_H   := 462
DMG_APP_X   := 178
DMG_APPS_X  := 482
DMG_ICON_Y  := 214
DMG_ICON_SIZE := 96

# SDK to build against. The macOS 27 SDK turns SwiftUI's @State into a macro
# whose compiler plugin the Command Line Tools do not ship, so a CLT-only build
# against it fails with "plugin for module 'SwiftUIMacros' not found". The newest
# 26.x SDK predates that and builds the same app (deployment target 14).
# Override with `make SDKROOT=...` once the CLT carries the plugin.
SDKROOT     ?= $(shell sdk=$$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1); if [ -n "$$sdk" ]; then echo "$$sdk"; else xcrun --sdk macosx --show-sdk-path; fi)
export SDKROOT

# Signing identity, auto-detected. Once a Developer ID Application certificate is
# in the login keychain it is used automatically; until then everything falls
# back to ad-hoc ("-"), which builds fine but cannot be notarized.
#
# Detected rather than pasted because the identity string has to match exactly,
# and a typo yields a confusing codesign error rather than an obvious one.
# Override explicitly with `make dmg SIGN_ID="..."` if there are several.
DETECTED_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
                 | grep "Developer ID Application" | head -1 \
                 | sed -E 's/^[^"]*"([^"]*)".*$$/\1/')
SIGN_ID     ?= $(if $(DETECTED_ID),$(DETECTED_ID),-)
# Team ID lives in parentheses at the end of the identity name.
TEAM_ID     := $(shell echo '$(SIGN_ID)' | sed -nE 's/.*\(([A-Z0-9]+)\)$$/\1/p')
NOTARY_PROFILE ?=

# Reports how big an artifact actually is.
#
# Deliberately not `du -h`, which reports *allocated blocks* rather than file
# size. On APFS the image that `hdiutil convert` writes and `codesign` then
# rewrites carries a lot of allocated-but-unused extents, so `du` claimed 2.6M
# for a 1.66 MB file — and copying that same file anywhere reports 1.6M, which
# proves the overhead belongs to the inode and not to the bytes. The build was
# quoting the wrong number by 60%, which is a bad thing to be wrong about when
# the whole point is telling someone what they are about to download.
.PHONY: report-size
report-size:
	@bytes=$$(stat -f%z "$(FILE)"); \
	mb=$$(awk -v b=$$bytes 'BEGIN { printf "%.2f", b / 1000000 }'); \
	extra='$(EXTRA)'; \
	if [ -n "$$extra" ]; then \
	  printf '  %s bytes (%s MB)  \302\267  %s\n' "$$bytes" "$$mb" "$$extra"; \
	else \
	  printf '  %s bytes (%s MB)\n' "$$bytes" "$$mb"; \
	fi

# Fails the build if the app's fallback version disagrees with VERSION.
#
# The app reads its version out of the bundle at runtime, so VERSION below is the
# real source. The one literal left in About.swift only covers running the
# executable directly out of .build/release, where there is no Info.plist — but a
# second copy is a second copy, and the previous arrangement had the app claiming
# 0.1.0 from inside a disk image named 1.1.
# So the docs can name the current artefact without hardcoding a version that
# goes stale the next time VERSION moves.
.PHONY: print-version
print-version:
	@echo "$(VERSION)"

.PHONY: check-version
check-version:
	@literal=$$(sed -nE 's/.*developmentVersion = "([^"]+)".*/\1/p' "Sources/$(APP_NAME)/About.swift"); \
	if [ -z "$$literal" ]; then \
	  echo "error: could not find developmentVersion in Sources/$(APP_NAME)/About.swift"; exit 1; \
	fi; \
	if [ "$$literal" != "$(VERSION)" ]; then \
	  echo "error: version drift"; \
	  echo "  Makefile VERSION:                $(VERSION)"; \
	  echo "  About.swift developmentVersion:  $$literal"; \
	  exit 1; \
	fi

.PHONY: signing-status
# Prints what the build would do right now, so the state of signing is never a
# guess.
signing-status:
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  echo "signing:   ad-hoc (no Developer ID Application certificate found)"; \
	  echo "notarize:  not possible — see RELEASING.md"; \
	else \
	  echo "signing:   $(SIGN_ID)"; \
	  echo "team id:   $(TEAM_ID)"; \
	  echo "notarize:  make notarize NOTARY_PROFILE=<profile>"; \
	fi
	@printf 'notarytool: '; xcrun --find notarytool 2>/dev/null || echo "MISSING"

.PHONY: all build build-x86 app app-universal run install dist dmg dmg-only \
        notarize notarize-app release verify-release clean helper-selftest

all: app

build:
	swift build -c release

# Intel slice. Separate scratch path so the two architectures do not fight over
# one build directory.
build-x86:
	swift build -c release --scratch-path .build-x86 \
	  --triple x86_64-apple-macosx14.0

# Fast path for local work: host architecture only.
app: build
	@$(MAKE) --no-print-directory bundle EXEC_SRC="$(BIN)" HELPER_SRC="$(HELPER_BIN)" LIPO=0

# What gets shared. Runs on both Apple Silicon and Intel.
app-universal: build build-x86
	@$(MAKE) --no-print-directory bundle EXEC_SRC="$(BIN)" LIPO=1

# Assembles the .app around an already-built executable.
bundle:
	@$(MAKE) --no-print-directory check-version
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	mkdir -p "$(APP_BUNDLE)/Contents/Library/LaunchDaemons"
	@if [ "$(LIPO)" = "1" ]; then \
	  lipo -create "$(BIN)" "$(BIN_X86)" -output "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	  echo "universal: $$(lipo -archs "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)")"; \
	  lipo -create "$(HELPER_BIN)" "$(HELPER_BIN_X86)" -output "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)"; \
	  echo "helper universal: $$(lipo -archs "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)")"; \
	else \
	  cp "$(EXEC_SRC)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	  cp "$(HELPER_SRC)" "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)"; \
	fi
	# SMAppService.daemon(plistName:) looks for the plist here.
	plutil -lint -s "$(HELPER_PLIST)"
	cp "$(HELPER_PLIST)" "$(APP_BUNDLE)/Contents/Library/LaunchDaemons/"
	rm -rf "$(BUILD_DIR)/AppIcon.iconset"
	"$(BIN)" --render-icon "$(BUILD_DIR)/AppIcon.iconset"
	iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	printf '%s' 'APPL????' > "$(APP_BUNDLE)/Contents/PkgInfo"
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '	<key>CFBundleIdentifier</key>' \
	  '	<string>$(BUNDLE_ID)</string>' \
	  '	<key>CFBundleName</key>' \
	  '	<string>$(APP_NAME)</string>' \
	  '	<key>CFBundleExecutable</key>' \
	  '	<string>$(APP_NAME)</string>' \
	  '	<key>CFBundlePackageType</key>' \
	  '	<string>APPL</string>' \
	  '	<key>CFBundleIconFile</key>' \
	  '	<string>AppIcon</string>' \
	  '	<key>CFBundleShortVersionString</key>' \
	  '	<string>$(VERSION)</string>' \
	  '	<key>CFBundleVersion</key>' \
	  '	<string>$(VERSION)</string>' \
	  '	<key>NSHumanReadableCopyright</key>' \
	  '	<string>Built by $(AUTHOR) ($(EMAIL))</string>' \
	  '	<key>LSUIElement</key>' \
	  '	<true/>' \
	  '	<key>NSHighResolutionCapable</key>' \
	  '	<true/>' \
	  '	<key>LSMinimumSystemVersion</key>' \
	  '	<string>14.0</string>' \
	  '</dict>' \
	  '</plist>' > "$(APP_BUNDLE)/Contents/Info.plist"
	# Helper first: the app's signature seals nested code, so anything inside
	# Contents/MacOS has to be signed before the bundle is. --identifier is what
	# the app's code-signing requirement on the helper checks.
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  codesign --force -s - --identifier "$(HELPER_ID)" \
	    "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)"; \
	  codesign --force -s - "$(APP_BUNDLE)"; \
	else \
	  echo "signing with: $(SIGN_ID)"; \
	  codesign --force --options runtime --timestamp --identifier "$(HELPER_ID)" \
	    -s "$(SIGN_ID)" "$(APP_BUNDLE)/Contents/MacOS/$(HELPER_NAME)"; \
	  codesign --force --options runtime --timestamp \
	    -s "$(SIGN_ID)" "$(APP_BUNDLE)"; \
	fi
	@echo "Built $(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

# Shareable archive: universal binary, plus the instructions a recipient needs to
# get past Gatekeeper. ditto rather than zip, because zip mangles the bundle's
# symlinks and resource forks.
dist: app-universal
	mkdir -p "$(DIST_DIR)"
	rm -f "$(ZIP)"
	cp SHARING.md "$(DIST_DIR)/READ-ME-FIRST.md"
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(ZIP)"
	@echo
	@echo "  $(ZIP)"
	@$(MAKE) --no-print-directory report-size FILE="$(ZIP)" \
	  EXTRA="$$(lipo -archs "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)")"
	@echo
	@echo "  Send the zip together with $(DIST_DIR)/READ-ME-FIRST.md."
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  echo "  Ad-hoc signed, not notarised: macOS blocks the first open until the"; \
	  echo "  recipient allows it in System Settings > Privacy & Security."; \
	else \
	  echo "  Prefer 'make dmg' for sharing: the disk image window shows where"; \
	  echo "  to drag Hotch and what happens next, and a zip has nowhere to put that."; \
	fi

# Drag-to-install disk image. Nicer than the zip, and the right container to
# notarize once there is a Developer ID.
#
# It does NOT remove the Gatekeeper warning on its own: quarantine is applied to
# whatever a browser downloads, and an ad-hoc signature cannot satisfy it no
# matter how the app is packaged. Only notarization does. See SHARING.md.
dmg: app-universal
	@$(MAKE) --no-print-directory dmg-only

# The image build on its own, without rebuilding the app first.
#
# `release` needs this split: it staples a notarization ticket into the .app,
# and rebuilding the bundle would delete the ticket it just waited on.
dmg-only:
	mkdir -p "$(DIST_DIR)"
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/.background"
	cp -R "$(APP_BUNDLE)" "$(STAGE)/"
	# The Applications symlink is what makes the window a drag-and-drop target.
	ln -s /Applications "$(STAGE)/Applications"
	# Rendered by the app itself, so the install instructions live in Swift next
	# to the behaviour they describe. See Views/InstallerArt.swift for why the
	# window has to carry them at all.
	#
	# The renderer reports the geometry it drew for, and that is compared against
	# the values above: if the two drift, Finder silently places the icons over
	# the wrong part of the background, which is exactly the kind of breakage
	# nobody notices until a recipient sees it.
	@out="$$("$(BIN)" --render-dmg-background "$(STAGE)/.background/background.tiff")"; \
	echo "$$out"; \
	want="window $(DMG_WIN_W)x$(DMG_WIN_H), app at $(DMG_APP_X),$(DMG_ICON_Y), applications at $(DMG_APPS_X),$(DMG_ICON_Y)"; \
	case "$$out" in \
	  *"$$want"*) ;; \
	  *) echo "error: Makefile dmg geometry disagrees with InstallerArt.swift"; \
	     echo "  wanted: $$want"; exit 1 ;; \
	esac
	# Read-write first: the Finder window layout is stored in the volume's own
	# .DS_Store, which cannot be written to a compressed image.
	rm -f "$(DMG_RW)" "$(DMG)"
	# Any already-mounted volume of the same name has to go first, and a plain
	# detach is not enough: an image left mounted from testing the last build is
	# usually busy (Finder has the window open), the detach quietly fails, and
	# macOS mounts the new one alongside it as "Hotch 1.0 1". Everything after
	# that addresses "/Volumes/$(VOL_NAME)" and so decorates the *old* volume,
	# which is how a release build ends up reporting a window it never wrote.
	#
	# Caught rather than shipped, because dmg-window-verify reads the .DS_Store
	# back — but the failure is confusing enough to be worth preventing.
	@while mount | grep -q " /Volumes/$(VOL_NAME) "; do \
	  echo "detaching a stale /Volumes/$(VOL_NAME) left over from earlier"; \
	  hdiutil detach "/Volumes/$(VOL_NAME)" -force -quiet 2>/dev/null || break; \
	done
	hdiutil create \
	  -volname "$(VOL_NAME)" \
	  -srcfolder "$(STAGE)" \
	  -fs HFS+ \
	  -format UDRW \
	  -size 64m \
	  -quiet \
	  "$(DMG_RW)"
	hdiutil attach "$(DMG_RW)" -readwrite -noverify -noautoopen -quiet
	@$(MAKE) --no-print-directory dmg-window
	# Volume housekeeping macOS creates on mount, which would otherwise be
	# compressed into the download. Spotlight is told not to index the volume so
	# a recipient's Mac does not bother either.
	rm -rf "/Volumes/$(VOL_NAME)/.fseventsd" "/Volumes/$(VOL_NAME)/.Trashes"
	touch "/Volumes/$(VOL_NAME)/.metadata_never_index"
	# Flush the .DS_Store Finder just wrote before pulling the volume out.
	sync
	# Finder or Spotlight can still hold the volume for a moment after the
	# .DS_Store write, which fails a plain detach with "resource busy" (16).
	@for i in 1 2 3 4 5; do \
	  hdiutil detach "/Volumes/$(VOL_NAME)" -quiet 2>/dev/null && exit 0; sleep 1; \
	done; \
	hdiutil detach "/Volumes/$(VOL_NAME)" -force -quiet
	# Shrink to the smallest the contents allow before compressing. Without this
	# the shipped image carries the slack of the writable one it was built from.
	hdiutil resize -sectors min "$(DMG_RW)" -quiet
	hdiutil convert "$(DMG_RW)" \
	  -format UDZO \
	  -imagekey zlib-level=9 \
	  -quiet \
	  -o "$(DMG)"
	rm -f "$(DMG_RW)"
	rm -rf "$(STAGE)"
	@if [ "$(SIGN_ID)" != "-" ]; then \
	  codesign --force --timestamp -s "$(SIGN_ID)" "$(DMG)"; \
	  echo "signed the disk image too"; \
	fi
	@echo
	@echo "  $(DMG)"
	@$(MAKE) --no-print-directory report-size FILE="$(DMG)" EXTRA="volume \"$(VOL_NAME)\""
	@echo
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  echo "  Ad-hoc signed, not notarised: macOS blocks the first open until the"; \
	  echo "  recipient allows it in Privacy & Security. A DMG changes the"; \
	  echo "  presentation, not the signature."; \
	else \
	  echo "  Signed but not yet notarised: macOS still asks before the first open."; \
	  echo "  To remove that step: make notarize NOTARY_PROFILE=<your-notarytool-profile>"; \
	fi
	@echo

# Tells Finder how the mounted volume should look, and then checks that it
# listened.
#
# Written to a file rather than a chain of `osascript -e` arguments because the
# ordering matters and has to stay readable. Finder applies these asynchronously:
# without the delays, the window options are set on a window that has not
# finished opening and are silently dropped — the first version of this target
# produced a volume that reported `background: none` and an arrangement of
# "arranged by creation date", which would have snapped both icons to a grid and
# ignored the positions entirely.
#
# The coordinates have to match Views/InstallerArt.swift, which prints them when
# it renders — Finder positions icons from the top left of the window, in the
# same space the background image is drawn in.
.PHONY: dmg-window
dmg-window:
	@printf '%s\n' \
	  'tell application "Finder"' \
	  '  -- Hoisted out of the tell blocks below on purpose: inside' \
	  '  -- `tell its icon view options`, a `disk "..."` or `POSIX file` term' \
	  '  -- resolves against the view options and errors with -10006.' \
	  '  set bgFile to (POSIX file "/Volumes/$(VOL_NAME)/.background/background.tiff") as alias' \
	  '  tell disk "$(VOL_NAME)"' \
	  '    open' \
	  '    -- Wait for the window to exist AND be populated, rather than sleeping' \
	  '    -- a fixed second and hoping. The fixed delay worked until it did not:' \
	  '    -- on a loaded machine the window was not addressable yet and setting an' \
	  '    -- icon position failed with -10006, aborting the whole build.' \
	  '    set ready to false' \
	  '    repeat 60 times' \
	  '      try' \
	  '        if (count of items of container window) is greater than 1 then' \
	  '          set ready to true' \
	  '          exit repeat' \
	  '        end if' \
	  '      end try' \
	  '      delay 0.25' \
	  '    end repeat' \
	  '    if not ready then error "Finder never populated the disk image window"' \
	  '' \
	  '    -- Items being addressable does NOT mean the window will accept view' \
	  '    -- options yet, and setting them too early fails *silently* — no error,' \
	  '    -- just a volume that opens 48pt, grid-arranged and plain white. So this' \
	  '    -- sets them, reads `icon size` back, and retries until it sticks.' \
	  '    -- Reading back is the only way to know: the background picture, set in' \
	  '    -- the same block, cannot be read back at all on current macOS.' \
	  '    set styled to false' \
	  '    repeat 24 times' \
	  '      try' \
	  '        tell container window' \
	  '          set current view to icon view' \
	  '          set toolbar visible to false' \
	  '          set statusbar visible to false' \
	  '          set bounds to {240, 130, 240 + $(DMG_WIN_W), 130 + $(DMG_WIN_H)}' \
	  '          -- A tell block, not `set x of opts to ...` through an' \
	  '          -- intermediate variable: the variable form is accepted without' \
	  '          -- error and then ignored.' \
	  '          tell its icon view options' \
	  '            set arrangement to not arranged' \
	  '            set icon size to $(DMG_ICON_SIZE)' \
	  '            set text size to 12' \
	  '            set label position to bottom' \
	  '            set shows item info to false' \
	  '            set background picture to bgFile' \
	  '          end tell' \
	  '        end tell' \
	  '      end try' \
	  '      try' \
	  '        if (icon size of icon view options of container window) is $(DMG_ICON_SIZE) then' \
	  '          set styled to true' \
	  '          exit repeat' \
	  '        end if' \
	  '      end try' \
	  '      delay 0.25' \
	  '    end repeat' \
	  '    if not styled then error "Finder would not accept the icon view options"' \
	  '    delay 1' \
	  '    -- Positions after the view options, or "not arranged" undoes them.' \
	  '    -- Retried because this is the step that failed transiently: Finder' \
	  '    -- accepts the window long before it will accept an item inside it.' \
	  '    set placed to false' \
	  '    repeat 20 times' \
	  '      try' \
	  '        set position of item "$(APP_NAME).app" of container window to {$(DMG_APP_X), $(DMG_ICON_Y)}' \
	  '        set position of item "Applications" of container window to {$(DMG_APPS_X), $(DMG_ICON_Y)}' \
	  '        set placed to true' \
	  '        exit repeat' \
	  '      end try' \
	  '      delay 0.25' \
	  '    end repeat' \
	  '    if not placed then error "Finder would not accept the icon positions"' \
	  '    delay 1' \
	  '' \
	  '    -- `update` with the window still OPEN is what commits the layout to' \
	  '    -- the volume .DS_Store. Closing the window first reverts the icon view' \
	  '    -- options to defaults on the way out: an earlier version of this' \
	  '    -- ended with `close` and produced an image that reported iconSize 48,' \
	  '    -- arrangeBy dateCreated and no background at all. The volume is about' \
	  '    -- to be detached, which closes the window anyway.' \
	  '    update without registering applications' \
	  '    delay 3' \
	  '  end tell' \
	  'end tell' > "$(BUILD_DIR)/dmg-window.applescript"
	@osascript "$(BUILD_DIR)/dmg-window.applescript"
	@sync
	@$(MAKE) --no-print-directory dmg-window-verify

# Fails the build if Finder did not persist the layout. A disk image whose
# background quietly reverted to white looks fine here and wrong on the
# recipient's Mac, which is the worst place to find out — the whole reason for
# the background is that the recipient reads it.
#
# Reads the volume's .DS_Store instead of asking Finder, because Finder answers
# from live state rather than from what it wrote and the two disagree. See the
# header of the script for the specifics.
.PHONY: dmg-window-verify
dmg-window-verify:
	@python3 tools/verify-dmg-window.py "/Volumes/$(VOL_NAME)" \
	  --icon-size $(DMG_ICON_SIZE) \
	  --background background.tiff \
	  --item "$(APP_NAME).app=$(DMG_APP_X),$(DMG_ICON_Y)" \
	  --item "Applications=$(DMG_APPS_X),$(DMG_ICON_Y)"

# Submits the DMG to Apple and staples the ticket. Needs a Developer ID and a
# stored notarytool profile:
#
#   xcrun notarytool store-credentials hotch \
#     --apple-id you@example.com --team-id TEAMID
#
# Enter the app-specific password only at notarytool's hidden prompt. Passing
# --password can leave the secret in shell history, process arguments, or an
# agent's recorded command. The profile stays in Keychain and is not bundled.
#
# After this the DMG opens with a double click on any Mac, with no xattr step and
# no security warning.
notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
	  echo "error: set NOTARY_PROFILE (see the comment above this target)"; exit 1; \
	fi
	@if [ ! -f "$(DMG)" ]; then \
	  echo "error: $(DMG) does not exist — run 'make dmg SIGN_ID=...' first"; exit 1; \
	fi
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	spctl --assess --type open --context context:primary-signature -vv "$(DMG)"
	@echo "notarized and stapled: $(DMG)"

# Notarizes the .app itself and staples the ticket into the bundle.
#
# Stapling the disk image is not enough. The image is a delivery container that
# gets thrown away: what survives is the .app dragged out of it into
# /Applications, and that copy carries no ticket unless one was stapled into the
# bundle *before* the image was built. Without it Gatekeeper has to ask Apple
# over the network at first launch, so a recipient who is offline — or behind a
# firewall that blocks Apple's notary endpoint — gets "Apple could not verify
# Hotch is free of malware", whose only buttons are Move to Trash and Done.
#
# `syspolicy_check distribution` calls the missing ticket a Fatal error, and it
# is the check this target exists to satisfy.
#
# notarytool cannot take a bundle directly, hence the zip; the zip is only a
# transport for the submission and is deleted afterwards.
notarize-app:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
	  echo "error: set NOTARY_PROFILE (see the comment above 'notarize')"; exit 1; \
	fi
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
	  echo "error: $(APP_BUNDLE) does not exist — run 'make app-universal' first"; exit 1; \
	fi
	rm -f "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	ditto -c -k --sequesterRsrc --keepParent \
	  "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME)-notarize.zip" \
	  --keychain-profile "$(NOTARY_PROFILE)" --wait
	rm -f "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler validate "$(APP_BUNDLE)"
	@echo "ticket stapled into $(APP_BUNDLE)"

# The whole shipping path, in the one order that produces a clean install:
# build universal, notarize and staple the app, seal the stapled app into the
# image, then notarize and staple the image too.
#
# Doing it as separate `make` invocations rather than prerequisites, because
# prerequisites of `dmg` would rebuild the bundle and discard its ticket.
release:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
	  echo "error: set NOTARY_PROFILE (see the comment above 'notarize')"; exit 1; \
	fi
	@if [ "$(SIGN_ID)" = "-" ]; then \
	  echo "error: no Developer ID found — a release cannot be ad-hoc signed"; exit 1; \
	fi
	@$(MAKE) --no-print-directory app-universal
	@$(MAKE) --no-print-directory notarize-app NOTARY_PROFILE="$(NOTARY_PROFILE)"
	@$(MAKE) --no-print-directory dmg-only
	@$(MAKE) --no-print-directory notarize NOTARY_PROFILE="$(NOTARY_PROFILE)"
	@$(MAKE) --no-print-directory verify-release

# What a buyer's Mac will conclude, asked here instead of finding out from them.
#
# Mounts the shipped image and runs Apple's own pre-distribution check against
# the app inside it, which is stricter than spctl: spctl passes on a machine
# that can reach Apple's notary service, and so hides exactly the missing-ticket
# case this verifies.
verify-release:
	@echo "== disk image =="
	@spctl -a -t open --context context:primary-signature -vv "$(DMG)"
	@xcrun stapler validate "$(DMG)" > /dev/null && echo "$(DMG): ticket stapled"
	@hdiutil detach "/Volumes/$(VOL_NAME)" -quiet 2>/dev/null || true
	@hdiutil attach "$(DMG)" -nobrowse -readonly -quiet
	@echo "== app inside it =="
	@spctl -a -t exec -vv "/Volumes/$(VOL_NAME)/$(APP_NAME).app"
	@codesign --verify --deep --strict "/Volumes/$(VOL_NAME)/$(APP_NAME).app" \
	  && echo "signature: valid, deep, strict"
	@codesign --verify --strict \
	  -R='identifier "$(HELPER_ID)" and anchor apple generic and certificate leaf[subject.OU] = "$(TEAM_ID)"' \
	  "/Volumes/$(VOL_NAME)/$(APP_NAME).app/Contents/MacOS/$(HELPER_NAME)" \
	  && echo "helper: signed as $(HELPER_ID), team $(TEAM_ID)"
	@codesign --verify --strict \
	  -R='identifier "$(BUNDLE_ID)" and anchor apple generic and certificate leaf[subject.OU] = "$(TEAM_ID)"' \
	  "/Volumes/$(VOL_NAME)/$(APP_NAME).app" \
	  && echo "app: satisfies the helper's client requirement"
	@test -f "/Volumes/$(VOL_NAME)/$(APP_NAME).app/Contents/Library/LaunchDaemons/$(notdir $(HELPER_PLIST))" \
	  && echo "helper plist: present"
	@xcrun stapler validate "/Volumes/$(VOL_NAME)/$(APP_NAME).app" > /dev/null \
	  && echo "ticket: stapled into the app"
	@plutil -extract CFBundleShortVersionString raw \
	  "/Volumes/$(VOL_NAME)/$(APP_NAME).app/Contents/Info.plist" \
	  | xargs -I{} sh -c 'test "{}" = "$(VERSION)" \
	    && echo "version: {} (matches VERSION)" \
	    || { echo "error: bundle says {} but VERSION is $(VERSION)"; exit 1; }'
	@echo "== Apple pre-distribution check =="
	@syspolicy_check distribution "/Volumes/$(VOL_NAME)/$(APP_NAME).app"
	@hdiutil detach "/Volumes/$(VOL_NAME)" -quiet

# Runs the helper's scripted state-machine test. Prints pmset commands instead of
# running them and touches nothing in launchd; safe on any machine.
helper-selftest: build
	"$(HELPER_BIN)" --self-test

clean:
	rm -rf "$(BUILD_DIR)" .build .build-x86

# Isolated checks: no real provider requests, clipboard capture, or power changes.
.PHONY: check
check: check-version build
	"$(BIN)" --check-rail
	"$(BIN)" --check-session-handoff
	"$(BIN)" --check-welcome
	"$(BIN)" --check-focus
	"$(BIN)" --check-system-demand
	"$(BIN)" --check-notch
	"$(BIN)" --check-credentials
	"$(HELPER_BIN)" --self-test
