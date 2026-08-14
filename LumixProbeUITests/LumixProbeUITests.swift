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

        XCTAssertTrue(app.buttons["Reconnect to GM1S-90C7E0"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Scan another camera QR code"].exists)
        XCTAssertFalse(app.staticTexts["This camera is remembered securely. iPhone can also Auto-Join it whenever its Wi-Fi is available."].exists)
    }

    func testDisconnectedGuideQRCodeScannerAndManualFallback() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["Enable the camera Wi-Fi"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Join from this iPhone"].exists)
        XCTAssertTrue(app.buttons["Scan camera QR code"].exists)
        XCTAssertTrue(app.buttons["Enter network details"].exists)
        XCTAssertTrue(app.buttons["start-location-log"].exists)
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

        app.buttons["Enter network details"].tap()
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

        let firstPhoto = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "open-camera-photo-")
        ).firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        firstPhoto.tap()

        XCTAssertTrue(app.buttons["save-camera-photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Demo scene 0025"].exists)
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

        let appVersion = app.staticTexts["app-version"]
        scrollToElement(appVersion)
        XCTAssertEqual(appVersion.label, "GM1 Sync · Version 1.0 (5)")

        let iconLink = app.buttons["app-icon-link"]
        scrollToElement(iconLink)
        iconLink.tap()
        XCTAssertTrue(app.navigationBars["App Icon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Lens"].exists)
        XCTAssertTrue(app.staticTexts["Blue Camera"].exists)
        XCTAssertTrue(app.staticTexts["Black Camera"].exists)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let blueIcon = app.buttons["app-icon-BlueCamera"]
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
