TMPDIR := /Users/josh/d/gcsf/.work/tmp
DD := /Users/josh/d/gcsf/.work/tmp/f0-dd
INSTALL := /Users/josh/d/gcsf/.work/tmp/f0-install
export TMPDIR

.PHONY: all build doctor test smoke install mount umount test-live clean

all: build

build:
	mkdir -p "$(TMPDIR)" "$(DD)"
	swift build
	xcodebuild -project GCSF.xcodeproj -scheme GCSFHost -configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath "$(DD)" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY= \
		AD_HOC_CODE_SIGNING_ALLOWED=NO \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

doctor:
	mkdir -p "$(TMPDIR)"
	bash doctor/doctor.sh

test:
	swift test

smoke:
	@echo "smoke is parked" >&2
	@exit 1

install: build
	mkdir -p "$(INSTALL)"
	cp "$(CURDIR)/.build/debug/gcsf" "$(INSTALL)/gcsf"
	rm -rf "$(INSTALL)/GCSFHost.app"
	cp -R "$(DD)/Build/Products/Debug/GCSFHost.app" "$(INSTALL)/GCSFHost.app"

mount:
	@echo "mount is parked" >&2
	@exit 1

umount:
	@echo "umount is parked" >&2
	@exit 1

test-live:
	@echo "test-live is parked" >&2
	@exit 1

clean:
	rm -rf "$(CURDIR)/.build" "$(DD)" "$(TMPDIR)/f0-doctor" "$(TMPDIR)/f0-doctor-swiftc.log" "$(INSTALL)"
