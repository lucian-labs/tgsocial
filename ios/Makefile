# tgsocial iOS — xcodegen + xcodebuild. Secrets come from Secrets.xcconfig (gitignored).

SCHEME      := tgsocial
PROJECT     := tgsocial.xcodeproj
BUNDLE_ID   := ca.lucianlabs.tgsocial
TEAM_ID     := L62T7W4NBF
DEVICE_ID   := 101D3D40-548A-52CA-84AA-247AA0306754
SIM         := platform=iOS Simulator,name=iPhone 17 Pro
DERIVED     := build/derivedData
PACKAGES    := build/SourcePackages
ARCHIVE     := build/tgsocial.xcarchive
EXPORT_DIR  := build/export
# App Store Connect API key id + issuer id: environment first, else Secrets.xcconfig (gitignored).
# The .p8 lives at ASC_API_KEY_PATH (default ~/.private_keys/AuthKey_<id>.p8, where altool also looks).
ASC_API_KEY      ?= $(shell sed -n 's/^ASC_API_KEY[[:space:]]*=[[:space:]]*//p' Secrets.xcconfig 2>/dev/null)
ASC_API_ISSUER   ?= $(shell sed -n 's/^ASC_API_ISSUER[[:space:]]*=[[:space:]]*//p' Secrets.xcconfig 2>/dev/null)
ASC_API_KEY_PATH ?= $(HOME)/.private_keys/AuthKey_$(ASC_API_KEY).p8
# xcodebuild needs the API key to resolve App Store profiles without an Xcode account signed in.
ASC_AUTH := $(if $(ASC_API_KEY),-authenticationKeyPath $(ASC_API_KEY_PATH) -authenticationKeyID $(ASC_API_KEY) -authenticationKeyIssuerID $(ASC_API_ISSUER),)
# Build number increases every archive (PRODUCT.md §6): UTC minute stamp, strictly increasing per archive.
BUILD_NUMBER   ?= $(shell date -u +%Y%m%d%H%M)

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-clonedSourcePackagesDirPath $(PACKAGES) -derivedDataPath $(DERIVED)

.PHONY: gen build test device archive export upload clean

gen:
	@test -f Secrets.xcconfig || (echo "Secrets.xcconfig missing — copy Secrets.xcconfig.example and fill it in." && exit 1)
	xcodegen generate

build:
	$(XCB) -configuration Debug -destination '$(SIM)' build

test:
	$(XCB) -configuration Debug -destination '$(SIM)' test

device:
	$(XCB) -configuration Debug -destination 'id=$(DEVICE_ID)' -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE_ID) $(DERIVED)/Build/Products/Debug-iphoneos/tgsocial.app
	xcrun devicectl device process launch --device $(DEVICE_ID) $(BUNDLE_ID)

archive:
	$(XCB) -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates $(ASC_AUTH) \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) -archivePath $(ARCHIVE) archive

export:
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions-AppStore.plist \
		-exportPath $(EXPORT_DIR) -allowProvisioningUpdates $(ASC_AUTH)

upload:
	@test -n "$(ASC_API_KEY)" -a -n "$(ASC_API_ISSUER)" || (echo "ASC_API_KEY / ASC_API_ISSUER missing — set them in Secrets.xcconfig or the environment." && exit 1)
	xcrun altool --upload-app -f $(EXPORT_DIR)/tgsocial.ipa -t ios --apiKey $(ASC_API_KEY) --apiIssuer $(ASC_API_ISSUER)

clean:
	rm -rf $(DERIVED) $(ARCHIVE) $(EXPORT_DIR)
