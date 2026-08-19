import XCTest

final class LumixProbeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestNoRememberedCamera"]
    }

    func testRememberedCameraReconnectAppearsAlongsideQRCodeScanner() throws {
        app.launchArguments = ["-UITestRememberedCamera"]
        app.launch()

        XCTAssertTrue(app.buttons["Reconnect to GM1S-DEMO01"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Scan another camera QR code"].exists)
        XCTAssertTrue(app.staticTexts["Turn on your camera and reconnect Wi-Fi."].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["This camera is remembered securely. iPhone can also Auto-Join it whenever its Wi-Fi is available."].exists)
    }

    func testDisconnectedGuideQRCodeScannerAndManualFallback() throws {
        app.launch()

        let connectionHelp = app.buttons["camera-connection-help"]
        XCTAssertTrue(connectionHelp.waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["Enable the camera Wi-Fi"].exists)
        connectionHelp.tap()
        XCTAssertTrue(app.staticTexts["Enable the camera Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Join from this iPhone"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Leave its QR code on screen")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Connect to the camera Wi-Fi by scanning the QR code, or manually."].exists)
        XCTAssertTrue(app.buttons["Scan camera QR code"].exists)
        XCTAssertTrue(app.buttons["Enter wi-fi name and password"].exists)
        XCTAssertTrue(app.buttons["start-location-log"].exists)
        XCTAssertTrue(app.switches["auto-start-geotagging"].exists)
        XCTAssertTrue(app.staticTexts["Start geotagging on app start"].exists)
        XCTAssertFalse(app.staticTexts["Need help?"].exists)
        XCTAssertFalse(app.textFields["camera-ip-address"].exists)

        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }

        app.buttons["Scan camera QR code"].tap()
        app.tap()
        XCTAssertTrue(app.navigationBars["Scan camera Wi-Fi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Cancel"].tap()

        app.buttons["Enter wi-fi name and password"].tap()
        XCTAssertTrue(app.navigationBars["Join Camera Wi-Fi"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["manual-wifi-ssid"].exists)
        XCTAssertTrue(app.secureTextFields["manual-wifi-password"].exists)
        XCTAssertFalse(app.buttons["join-manual-camera-wifi"].isEnabled)
        app.buttons["Cancel"].tap()
    }

    func testConnectedGalleryPaginationSelectionAndDetail() throws {
        app.launchArguments = ["-UITestConnectedGallery"]
        app.launch()

        XCTAssertTrue(app.scrollViews["camera-gallery"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Scan camera QR code"].exists)
        let mediaCount = app.staticTexts["camera-gallery-count"]
        XCTAssertTrue(mediaCount.exists)
        XCTAssertEqual(mediaCount.label, "25 images · 0 videos")
        XCTAssertTrue(app.buttons["download-all-new-camera-media"].exists)

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "open-camera-photo-")
        ).firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        firstPhoto.tap()

        XCTAssertTrue(app.buttons["save-camera-photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Demo scene 0025"].exists)
        XCTAssertTrue(app.staticTexts["JPEG · RAW"].exists)
        XCTAssertTrue(app.staticTexts["Location"].exists)
        XCTAssertFalse(app.staticTexts["Camera item"].exists)
        XCTAssertTrue(app.staticTexts["Could not verify geotag"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Preparing metadata check…"].exists)
        XCTAssertFalse(app.buttons["Check original metadata"].exists)
        XCTAssertFalse(app.buttons["photo-metadata-diagnostic"].exists)
        XCTAssertFalse(app.staticTexts["Original metadata not verified"].exists)
        app.swipeLeft()
        XCTAssertTrue(app.navigationBars["Demo scene 0024"].waitForExistence(timeout: 5))
        app.swipeRight()
        XCTAssertTrue(app.navigationBars["Demo scene 0025"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["toggle-photo-selection"].tap()
        app.buttons["Gallery actions"].tap()
        XCTAssertFalse(app.buttons["Select newest 10"].exists)
        app.buttons["Select all items"].tap()
        XCTAssertTrue(app.buttons["import-selected-photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["25 selected"].exists)
        XCTAssertTrue(app.segmentedControls["camera-import-format"].exists)
        XCTAssertTrue(app.buttons["JPEG"].exists)
        XCTAssertTrue(app.buttons["JPEG + RAW"].exists)
        XCTAssertTrue(app.buttons["RAW"].exists)

        app.buttons["toggle-photo-selection"].tap()
        XCTAssertEqual(mediaCount.label, "25 images · 0 videos")
    }

    func testSettingsCompatibilityAndAppIcons() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["landing-title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["image-app-alternative-text"].waitForExistence(timeout: 8))

        app.buttons["app-settings-link"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Remote Shooting & View → Direct → Image App")
            ).firstMatch.exists
        )
        XCTAssertTrue(app.textFields["camera-ip-address"].exists)
        XCTAssertTrue(app.buttons["check-camera-connection"].exists)
        XCTAssertFalse(app.buttons["start-location-log"].exists)

        let compatibilityLink = app.buttons["camera-compatibility-link"]
        scrollToElement(compatibilityLink)
        compatibilityLink.tap()
        XCTAssertTrue(app.navigationBars["Camera candidates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Panasonic DMC-GM1S"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        let repositoryLink = app.descendants(matching: .any)["github-repository-link"].firstMatch
        scrollToElement(repositoryLink)
        XCTAssertTrue(app.staticTexts["GitHub repository"].exists)

        let appVersion = app.staticTexts["app-version"]
        scrollToElement(appVersion)
        XCTAssertTrue(appVersion.label.hasPrefix("GM1 Sync · Version 1.0.1 ("))

        let iconLink = app.buttons["app-icon-link"]
        scrollToElement(iconLink)
        iconLink.tap()
        XCTAssertTrue(app.navigationBars["App Icon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Blue Camera"].exists)
        XCTAssertTrue(app.staticTexts["Lens"].exists)
        XCTAssertTrue(app.staticTexts["Black Camera"].exists)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let blueIcon = app.buttons["app-icon-primary"]
        if blueIcon.isEnabled {
            blueIcon.tap()
            let confirmation = springboard.alerts.firstMatch
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            XCTAssertTrue(confirmation.staticTexts["You have changed the icon for “GM1 Sync”."].exists)
            confirmation.buttons["OK"].tap()
        }
        let selected = NSPredicate(format: "value CONTAINS %@", "Selected")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: selected, object: blueIcon)],
                timeout: 8
            ),
            .completed
        )
    }

    func testLocationLogCanStartAndStop() throws {
        app.launch()

        let startButton = app.buttons["start-location-log"]
        scrollToElement(startButton)
        startButton.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionAlert = springboard.alerts.firstMatch
        if permissionAlert.waitForExistence(timeout: 2) {
            for label in ["Allow While Using App", "Allow Once", "OK"] {
                let button = permissionAlert.buttons[label]
                if button.exists {
                    button.tap()
                    break
                }
            }
        }

        let stopButton = app.buttons["stop-location-log"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Location log running"].exists)
        stopButton.tap()
        XCTAssertTrue(app.buttons["start-location-log"].waitForExistence(timeout: 5))
    }

    func testConnectedCameraAndEveryProtocolAction() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the physical iPhone connected to a powered GM1S.")
#else
        app.launch()
        XCTAssertTrue(app.scrollViews["camera-gallery"].waitForExistence(timeout: 20))
        openDiagnostics()

        tap("Probe getstate")
        waitForResult("getstate complete", timeout: 12)
        tap("Request camera access")
        waitForResult("Access request complete", timeout: 12)
        tap("Run full probe")
        waitForResult("Full probe complete", timeout: 75)
        tap("Probe media server directly")
        waitForResult("Direct browse complete", timeout: 20)
        tap("Browse final 5 records")
        waitForResult("Final-five browse complete", timeout: 25)
        tap("Download first original JPEG")
        waitForResult("Original JPEG downloaded", timeout: 60)
#endif
    }

    private func openDiagnostics() {
        app.buttons["app-settings-link"].tap()
        let link = app.buttons["camera-diagnostics-link"]
        scrollToElement(link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
    }

    private func tap(_ label: String) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing button: \(label)")
        XCTAssertTrue(button.isEnabled, "Disabled button: \(label)")
        button.tap()
    }

    private func waitForResult(_ result: String, timeout: TimeInterval) {
        let text = app.staticTexts["lastResult"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing last-result status")
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", result, result)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: text)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Last result did not become: \(result)"
        )
    }

    private func scrollToElement(_ element: XCUIElement) {
        var attempts = 0
        while !element.isHittable, attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.exists)
    }
}
