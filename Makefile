# Harvest dev tasks. Encapsulates the build/test incantations so they're not hand-assembled.
#
# Key rule baked in: each mode uses its OWN derivedData dir. Running two xcodebuild invocations
# against one -derivedDataPath corrupts results (seen as all-NO-RESULT test runs).

SCHEME      := Harvest
BUNDLE_ID   := com.camgrigo.ReturnVisitNotebook
DEVICE_ID   := 6FE04D71-2467-5A6F-B287-4A5B4ED6CB2C
DEVICE_DEST := platform=iOS,id=$(DEVICE_ID)
GENERIC     := generic/platform=iOS

DD_BUILD := /tmp/harvest-dd
DD_UNIT  := /tmp/harvest-dd-unit
DD_UI    := /tmp/harvest-dd-ui
DD_SIM   := /tmp/harvest-dd-sim

# Simulator: the whole UI suite runs in one shot here (no tunnel/unlock babysitting), ~3x faster.
SIM_NAME    := Harvest-Test
SIM_DEVTYPE := com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
SIM_RUNTIME := com.apple.CoreSimulator.SimRuntime.iOS-27-0
SIM_DEST    := platform=iOS Simulator,name=$(SIM_NAME)

XCB := xcodebuild -scheme $(SCHEME) -allowProvisioningUpdates

# UI tests to run individually (the device tunnel drops if many share one runner).
UITESTS := testAppLaunchesWithoutCrashing testAccessibilityAudit testReturnKeySubmitsAndFilesVisit testSendButtonFilesVisit \
	testEditingInterestDoesNotCreateDuplicate testRenameUpdatesPersonInPlace \
	testPersonRowOpensDetail testSummarizeProducesReply testMapTabShowsControls \
	testMapSheetHasSearch testMapSearchFindsPerson \
	testMapStyleChooserShowsLooks testMapStyleChooserSelectsSatellite testMapBreadcrumbToggles \
	testMapShowEverythingStaysOnMap testPeopleTabListsFiledPerson

.PHONY: generate build build-device install launch test-unit test-ui sim test-unit-sim test-ui-sim clean help

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | sort

generate: ## Regenerate Harvest.xcodeproj from project.yml (run after adding/removing files)
	xcodegen generate

build: ## Compile for generic iOS (no device needed) — fastest error check
	$(XCB) -destination '$(GENERIC)' -derivedDataPath $(DD_BUILD) build

build-device: ## Build + sign for the physical iPhone
	$(XCB) -destination '$(DEVICE_DEST)' -derivedDataPath $(DD_BUILD) build

install: build-device ## Install the freshly built app on the iPhone
	xcrun devicectl device install app --device $(DEVICE_ID) \
		$$(find $(DD_BUILD)/Build/Products -name '$(SCHEME).app' -path '*iphoneos*' | head -1)

launch: ## Launch the app on the iPhone (terminates any existing instance)
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing $(BUNDLE_ID)

test-unit: ## Run the unit suite on device (own derivedData)
	$(XCB) -testPlan Unit -destination '$(DEVICE_DEST)' -derivedDataPath $(DD_UNIT) test

test-ui: ## Run UI tests one at a time on device (own derivedData; needs phone unlocked + awake)
	@for t in $(UITESTS); do \
		printf '%s :: ' "$$t"; \
		out=$$($(XCB) -testPlan UITests -destination '$(DEVICE_DEST)' -derivedDataPath $(DD_UI) \
			-only-testing:HarvestUITests/RVUITests/$$t test 2>&1); \
		if echo "$$out" | grep -q "$$t\].* passed"; then echo PASS; \
		elif echo "$$out" | grep -q "$$t\].* failed"; then echo FAIL; \
		elif echo "$$out" | grep -qi Locked; then echo DEVICE-LOCKED; \
		elif echo "$$out" | grep -qi crashed; then echo CRASH; \
		else echo NO-RESULT; fi; \
	done

sim: ## Create (if needed) and boot the iOS 27 test simulator
	@xcrun simctl list devices 2>/dev/null | grep -q '$(SIM_NAME) (' \
		|| xcrun simctl create '$(SIM_NAME)' '$(SIM_DEVTYPE)' '$(SIM_RUNTIME)'
	@xcrun simctl bootstatus '$(SIM_NAME)' -b >/dev/null 2>&1 || xcrun simctl boot '$(SIM_NAME)' 2>/dev/null || true

test-unit-sim: sim ## Run the unit suite on the simulator (own derivedData)
	$(XCB) -testPlan Unit -destination '$(SIM_DEST)' -derivedDataPath $(DD_SIM) test

test-ui-sim: sim ## Run the whole UI suite on the simulator in one shot (fast; MapKit test auto-skips)
	$(XCB) -testPlan UITests -destination '$(SIM_DEST)' -derivedDataPath $(DD_SIM) test

clean: ## Remove all derivedData dirs
	rm -rf $(DD_BUILD) $(DD_UNIT) $(DD_UI) $(DD_SIM)
