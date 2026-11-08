import XCTest

final class LumixProbeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestNoRememberedCamera", "-UITestDisconnected"]
    }

    func testWidgetStartAndStopLinksControlLocationLogging() throws {
        let permissionMonitor = addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            let allow = alert.buttons["Allow While Using App"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permissionMonitor) }
        app.launch()

        app.open(URL(string: "gm1sync://tracking/start")!)
        // Trigger interruption handling if this is the first location request. Tap the
        // title: the middle of the home screen is a camera job that would navigate away.
        app.staticTexts["landing-title"].tap()
        XCTAssertTrue(app.buttons["stop-location-log"].waitForExistence(timeout: 10))

        app.open(URL(string: "gm1sync://tracking/stop")!)
        XCTAssertTrue(app.buttons["start-location-log"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stop-location-log"].exists)
        app.activate()
        XCTAssertTrue(app.buttons["start-location-log"].exists)
    }

    func testRememberedCameraReconnectAppearsAlongsideQRCodeScanner() throws {
        app.launchArguments = ["-UITestRememberedCamera", "-UITestDisconnected"]
        app.launch()

        let photos = app.buttons["open-camera-photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 12))
        photos.tap()
        XCTAssertTrue(app.buttons["Join GM1S-DEMO01"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Scan another camera QR code"].exists)
        XCTAssertTrue(app.staticTexts["Turn on your camera and reconnect Wi-Fi."].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["This camera is remembered securely. iPhone can also Auto-Join it whenever its Wi-Fi is available."].exists)
    }

    func testDisconnectedGuideQRCodeScannerAndManualFallback() throws {
        app.launch()

        XCTAssertTrue(app.buttons["start-location-log"].waitForExistence(timeout: 12), "The location log is on the home screen")
        XCTAssertFalse(app.switches["auto-start-geotagging"].exists, "These settings live on the Geotagging settings screen")
        XCTAssertFalse(app.buttons["home-open-timeline-import"].exists, "Google Timeline import is only in Geotagging settings")
        XCTAssertTrue(app.buttons["open-live-view"].exists)
        XCTAssertTrue(app.buttons["open-push-transfer"].exists)
        let photos = app.buttons["open-camera-photos"]
        XCTAssertTrue(photos.exists)
        photos.tap()
        XCTAssertTrue(app.navigationBars["Get photos from the card"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Remote Shooting & View").exists, "The steps name the camera's Wi-Fi mode for this job")
        XCTAssertTrue(app.buttons["Scan camera QR code"].exists)
        XCTAssertTrue(app.buttons["Enter wi-fi name and password"].exists)
        XCTAssertFalse(app.textFields["camera-ip-address"].exists)

        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }

        let scanner = app.buttons["Scan camera QR code"]
        scrollToElement(scanner, towardTop: true)
        scanner.tap()
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

        app.navigationBars["Get photos from the card"].buttons.element(boundBy: 0).tap()
        let geotaggingSettings = app.buttons["open-geotagging-settings"]
        XCTAssertTrue(geotaggingSettings.waitForExistence(timeout: 5))
        geotaggingSettings.tap()
        XCTAssertTrue(app.navigationBars["Geotagging"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["auto-start-geotagging"].exists)
        XCTAssertTrue(app.buttons["import-google-timeline"].exists)
    }

    func testConnectedGalleryPaginationSelectionAndDetail() throws {
        app.launchArguments = ["-UITestConnectedGallery"]
        app.launch()

        XCTAssertTrue(element(labelContaining: "Connected to").waitForExistence(timeout: 8), "Home shows the connection")
        app.buttons["open-camera-photos"].tap()
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

    func testAboutCompatibilityAppIconsAndDeveloperSettings() throws {
        app.launch()
        XCTAssertTrue(app.staticTexts["landing-title"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["image-app-alternative-text"].waitForExistence(timeout: 8))
        XCTAssertFalse(element(labelContaining: "& other 2010-era Lumix cams").exists)
        XCTAssertFalse(app.buttons["app-settings-link"].exists, "There is no separate Settings screen")

        let cameraLink = app.links["GM1, GX7, and LX100"]
        XCTAssertTrue(cameraLink.waitForExistence(timeout: 5), "The example camera names are one link")
        cameraLink.tap()
        XCTAssertTrue(app.navigationBars["Camera candidates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Panasonic DMC-GM1S"].exists)
        app.navigationBars.buttons.firstMatch.tap()

        let headerIcon = app.buttons["home-app-icon"]
        XCTAssertTrue(headerIcon.waitForExistence(timeout: 5), "The chosen app icon is shown before the title")
        headerIcon.tap()
        XCTAssertTrue(app.navigationBars["App Icon"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        let developerNote = app.descendants(matching: .any)["about-developer-note"].firstMatch
        scrollToElement(developerNote)
        XCTAssertTrue(developerNote.label.contains("solo developer"))
        XCTAssertTrue(app.descendants(matching: .any)["feature-requests-link"].firstMatch.exists)

        let repositoryLink = app.descendants(matching: .any)["github-repository-link"].firstMatch
        scrollToElement(repositoryLink)
        XCTAssertTrue(repositoryLink.label.contains("View this app's code on GitHub"))

        let developerLink = app.buttons["developer-settings-link"]
        scrollToElement(developerLink)
        developerLink.tap()
        XCTAssertTrue(app.navigationBars["Developer settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            element(labelContaining: "Remote Shooting & View → Direct → Image App").exists,
            "The connection group moved here from the old Settings screen"
        )
        XCTAssertTrue(app.textFields["camera-ip-address"].exists)
        XCTAssertTrue(app.buttons["check-camera-connection"].exists)
        XCTAssertTrue(app.staticTexts["The GM1S normally uses 192.168.54.1 in Image App Direct mode."].exists)
        app.navigationBars.buttons.firstMatch.tap()

        let compatibilityLink = app.buttons["camera-compatibility-link"]
        scrollToElement(compatibilityLink)
        compatibilityLink.tap()
        XCTAssertTrue(app.navigationBars["Camera candidates"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        let appVersion = app.staticTexts["app-version"]
        scrollToElement(appVersion)
        XCTAssertNotNil(appVersion.label.range(of: #"^Retro LUMIX Sync · Version \d+(\.\d+)+ \(\d+\)$"#,
                                              options: .regularExpression))

        let iconLink = app.buttons["app-icon-link"]
        scrollToElement(iconLink, towardTop: true)
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
            XCTAssertTrue(confirmation.staticTexts["You have changed the icon for “Retro LUMIX Sync”."].exists)
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
        app.launchArguments = ["-UITestNoRememberedCamera"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["home-camera-connected"].waitForExistence(timeout: 20))
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

    func testRemoteShootingLiveViewShutterSettingsAndReturnToGallery() throws {
        app.launchArguments = ["-UITestConnectedGallery"]
        app.launch()

        let shoot = app.buttons["open-live-view"]
        XCTAssertTrue(shoot.waitForExistence(timeout: 8))
        shoot.tap()
        XCTAssertTrue(app.descendants(matching: .any)["remote-shooting-viewfinder"].waitForExistence(timeout: 5),
                      "Shoot from your iPhone opens the live view directly")

        let status = app.descendants(matching: .any)["remote-shooting-status"]
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 10), .completed, "Live view did not start")

        XCTAssertTrue(element(labelContaining: "512 photos remaining").waitForExistence(timeout: 8))
        app.buttons["remote-shutter-button"].tap()
        XCTAssertTrue(element(labelContaining: "511 photos remaining").waitForExistence(timeout: 10),
                      "The camera's remaining-shot count reflects the remote capture")

        let iso = app.buttons["remote-setting-iso"]
        XCTAssertTrue(iso.waitForExistence(timeout: 5))
        iso.tap()
        let option = app.buttons["800"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(element(labelContaining: "ISO 800").waitForExistence(timeout: 10),
                      "The readout shows the ISO value read back from the camera")

        app.segmentedControls["camera-view-picker"].buttons["Photos"].tap()
        XCTAssertTrue(app.scrollViews["camera-gallery"].waitForExistence(timeout: 8))
        let mediaCount = app.staticTexts["camera-gallery-count"]
        XCTAssertTrue(mediaCount.waitForExistence(timeout: 8))
    }

    func testWriteLocationsAndCameraClockFromTheGalleryMenu() throws {
        app.launchArguments = ["-UITestConnectedGallery"]
        app.launch()
        let photos = app.buttons["open-camera-photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 8))
        photos.tap()
        XCTAssertTrue(app.scrollViews["camera-gallery"].waitForExistence(timeout: 8))

        app.buttons["gallery-actions"].tap()
        let openWriter = app.buttons["open-location-writer"]
        XCTAssertTrue(openWriter.waitForExistence(timeout: 5))
        openWriter.tap()
        XCTAssertTrue(app.navigationBars["Write locations"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Can write locations from the app").waitForExistence(timeout: 8))
        XCTAssertTrue(element(labelContaining: "The camera decides which photos receive a location").exists)

        let write = app.buttons["geotag-write-start"]
        scrollToElement(write)
        write.tap()
        let confirm = app.buttons["Write locations"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(labelContaining: "The camera reports that it finished").waitForExistence(timeout: 20))
        let verify = app.buttons["geotag-verify"]
        scrollToElement(verify)
        XCTAssertTrue(verify.exists, "Verification is offered after the camera's finish")
        app.navigationBars["Write locations"].buttons["Close"].tap()

        app.buttons["gallery-actions"].tap()
        let openClock = app.buttons["open-camera-clock"]
        XCTAssertTrue(openClock.waitForExistence(timeout: 5))
        openClock.tap()
        XCTAssertTrue(app.navigationBars["Camera clock"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(labelContaining: "Camera reports").waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["camera-clock-set"].exists)
    }

    func testHomeOpensACameraToolDirectly() throws {
        app.launchArguments = ["-UITestConnectedGallery"]
        app.launch()
        let clock = app.buttons["home-open-camera-clock"]
        XCTAssertTrue(clock.waitForExistence(timeout: 8))
        scrollToElement(clock)
        clock.tap()
        XCTAssertTrue(app.navigationBars["Camera clock"].waitForExistence(timeout: 8),
                      "The clock opens on top of the connected camera screen")
        app.navigationBars["Camera clock"].buttons["Close"].tap()
        XCTAssertTrue(app.scrollViews["camera-gallery"].waitForExistence(timeout: 8))
    }

    func testSendWhileRecordingReceivesAndSavesAPhoto() throws {
        app.launchArguments += ["-UITestPushTransfer"]
        app.launch()

        let open = app.buttons["open-push-transfer"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        scrollToElement(open)
        open.tap()
        XCTAssertTrue(app.navigationBars["Send While Recording"].waitForExistence(timeout: 5))

        let start = app.buttons["start-push-transfer"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let join = app.buttons["join-camera-wifi"]
        XCTAssertTrue(join.waitForExistence(timeout: 5), "Receiving waits for the camera's Wi-Fi and offers to join it")
        XCTAssertTrue(join.label.contains("GM1S-DEMO"), "The button names the remembered network")
        join.tap()
        XCTAssertTrue(element(labelContaining: "Ready to receive").waitForExistence(timeout: 10),
                      "The scripted camera reads the receiver's description")
        XCTAssertTrue(element(labelContaining: "P1000001.JPG").waitForExistence(timeout: 10))
        XCTAssertTrue(element(labelContaining: "Saved to Photos").waitForExistence(timeout: 10),
                      "A received JPEG is reported saved once the importer finishes")
        XCTAssertTrue(element(labelContaining: "640 × 480").exists, "The received size is shown")

        app.buttons["close-push-transfer"].tap()
        XCTAssertTrue(app.buttons["open-push-transfer"].waitForExistence(timeout: 5))
    }

    private func element(labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openDiagnostics() {
        let link = app.buttons["developer-settings-link"]
        scrollToElement(link)
        link.tap()
        XCTAssertTrue(app.navigationBars["Developer settings"].waitForExistence(timeout: 5))
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

    private func scrollToElement(_ element: XCUIElement, towardTop: Bool = false) {
        var attempts = 0
        while !element.isHittable, attempts < 8 {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
            attempts += 1
        }
        XCTAssertTrue(element.exists)
    }
}
