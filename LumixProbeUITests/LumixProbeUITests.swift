import XCTest

final class LumixProbeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testConnectedCameraAndEveryProtocolAction() throws {
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Connected to GM1S"].waitForExistence(timeout: 12),
            "The GM1S must be reachable in Remote Shooting & View mode."
        )
        XCTAssertFalse(app.buttons["Scan camera QR code"].exists)

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

        tap("Probe getstate")
        waitForResult("getstate complete", timeout: 12)

        XCTAssertTrue(app.staticTexts["Connected to GM1S"].exists)
    }

    func testDisconnectedGuideAndQRCodeScanner() throws {
        app.launch()
        XCTAssertTrue(app.textFields["Camera IP"].waitForExistence(timeout: 8))

        let field = app.textFields["Camera IP"]
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        field.typeText("127.0.0.1")

        tap("Probe getstate")
        app.swipeDown()
        app.swipeDown()

        XCTAssertTrue(app.staticTexts["Enable the GM1S Wi-Fi"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Join from this iPhone"].exists)
        XCTAssertTrue(app.buttons["Scan camera QR code"].exists)
        XCTAssertFalse(app.staticTexts["Connected to GM1S"].exists)

        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allow = alert.buttons["Allow"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }

        app.buttons["Scan camera QR code"].tap()
        app.tap()

        XCTAssertTrue(app.navigationBars["Scan GM1S Wi-Fi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Point the iPhone at the QR code shown on the GM1S."].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
        app.buttons["Cancel"].tap()
    }

    func testConnectedCameraFinalStateOnly() throws {
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Connected to GM1S"].waitForExistence(timeout: 12),
            "The GM1S must remain reachable after media transfer."
        )
        tap("Probe getstate")
        waitForResult("getstate complete", timeout: 12)
        XCTAssertTrue(app.staticTexts["Connected to GM1S"].exists)
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

}
