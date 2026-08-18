import Foundation
#if os(iOS)
import Photos
#endif

struct DownloadedPhoto: Equatable {
    let fileURL: URL
    let captureDate: Date?
    let originalFilename: String
}

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var host = "192.168.54.1"
    @Published var log = "Join the camera's Wi-Fi network, then probe it.\n"
    @Published var isRunning = false
    @Published var resources: [LumixResource] = []
    @Published private(set) var downloadedPhoto: DownloadedPhoto?
    @Published private(set) var isSavingPhoto = false
    @Published var cameraClockOffsetMinutes: Double {
        didSet { defaults.set(cameraClockOffsetMinutes, forKey: Self.cameraClockOffsetKey) }
    }
    @Published private(set) var isCameraConnected = false
    @Published private(set) var connectionStatusMessage = "Checking for the camera…"
    @Published private(set) var lastResult = "Ready"

    private let logFileURL: URL
    private let defaults: UserDefaults
    private let wifiConnector = LumixWiFiConnector()
    let locationLogger: GeotagLocationLogger
    private var client: LumixClient { LumixClient(host: host.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private static let cameraClockOffsetKey = "cameraClockOffsetMinutes"

    init(defaults: UserDefaults = .standard, locationLogger: GeotagLocationLogger? = nil) {
        self.defaults = defaults
        self.locationLogger = locationLogger ?? GeotagLocationLogger()
        cameraClockOffsetMinutes = defaults.object(forKey: Self.cameraClockOffsetKey) as? Double ?? 0
        logFileURL = Self.makeLogFileURL()
        persistLog()
        print("[GM1Sync] Diagnostic session started")
    }

    private static func makeLogFileURL() -> URL {
#if os(iOS)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GM1Sync.log")
#else
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GM1Sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("GM1Sync.log")
#endif
    }

    func refreshConnectionStatus() async {
        connectionStatusMessage = "Checking for the camera…"
        do {
            let response = try await client.getState()
            isCameraConnected = response.text.contains("<result>ok</result>")
            connectionStatusMessage = isCameraConnected ? "Camera connected" : "Join the Wi-Fi network shown by the camera."
        } catch {
            isCameraConnected = false
            connectionStatusMessage = "Join the Wi-Fi network shown by the camera."
        }
    }

    func joinCameraWiFi(qrPayload: String) async {
        do {
            let ssid = try await wifiConnector.join(using: qrPayload)
            connectionStatusMessage = "Joining \(ssid)…"

            for _ in 0..<12 {
                try await Task.sleep(for: .seconds(1))
                do {
                    let response = try await client.getState()
                    guard response.text.contains("<result>ok</result>") else { continue }
                    isCameraConnected = true
                    connectionStatusMessage = "Camera connected"
                    append("Joined camera Wi-Fi and reached the camera.")
                    return
                } catch {
                    continue
                }
            }

            isCameraConnected = false
            connectionStatusMessage = "Wi-Fi joined, but the camera did not respond."
        } catch {
            isCameraConnected = false
            connectionStatusMessage = error.localizedDescription
            append("Wi-Fi QR connection ERROR: \(error.localizedDescription)")
        }
    }

    func probeState() {
        run { client in
            let response = try await client.getState()
            self.logResponse("getstate", response)
            self.lastResult = "getstate complete"
        }
    }

    func requestAccess() {
        run { client in
            let response = try await client.requestAccess()
            self.logResponse("req_acc", response)
            self.lastResult = "Access request complete"
        }
    }

    func runFullProbe() {
        run { client in
            self.append("=== FULL PROBE ===")
            let currentState = try await client.getState()
            self.logResponse("1 current getstate", currentState)

            do {
                let accessResponse = try await client.requestAccess()
                self.logResponse("2 req_acc", accessResponse)
            } catch {
                self.append("2 req_acc ERROR (may already be authorized): \(error.localizedDescription)")
            }

            await self.testContentInfo(client, label: "3 content info in CURRENT state")

            do {
                let recordModeResponse = try await client.setRecordMode()
                self.logResponse("4 switch recmode", recordModeResponse)
            } catch {
                self.append("4 recmode ERROR: \(error.localizedDescription)")
            }
            await self.testContentInfo(client, label: "5 content info in RECORD state")
            await self.testBrowse(client, label: "6 ContentDirectory browse in RECORD state")

            do {
                let playModeResponse = try await client.setPlayMode()
                self.logResponse("7 switch playmode", playModeResponse)
            } catch {
                self.append("7 playmode ERROR: \(error.localizedDescription)")
            }
            await self.testContentInfo(client, label: "8 content info in PLAY state")
            await self.testBrowse(client, label: "9 final five records in PLAY state")

            self.append("=== PROBE COMPLETE ===")
            self.lastResult = "Full probe complete"
        }
    }

    func browseLastFive() {
        run { client in
            let succeeded = await self.testBrowse(client, label: "manual final five")
            self.lastResult = succeeded ? "Final-five browse complete" : "Final-five browse failed"
        }
    }

    /// Bypasses cam.cgi so media-server-only camera connection modes can be tested.
    func browseFirstFiveDirectly() {
        run { client in
            let succeeded = await self.testDirectBrowse(client, label: "direct first five")
            self.lastResult = succeeded ? "Direct browse complete" : "Direct browse failed"
        }
    }

    func downloadFirstOriginal() {
        run { client in
            var candidates = self.resources.filter(\.isOriginalJPEG)
            if candidates.isEmpty {
                let result = try await client.browseLast(5)
                self.setResources(result.resources)
                candidates = result.resources.filter(\.isOriginalJPEG)
            }
            guard let original = candidates.last else { throw LumixError.noOriginalJPEG }
            self.append("Downloading \(original.profileName ?? "original JPEG"): \(original.url.absoluteString)")
            let file = try await client.download(original)
            let captureDate = PhotoCaptureDateReader.read(from: file)
            self.downloadedPhoto = DownloadedPhoto(
                fileURL: file,
                captureDate: captureDate,
                originalFilename: original.url.lastPathComponent.isEmpty
                    ? "lumix-original.jpg"
                    : original.url.lastPathComponent
            )
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            self.append("Downloaded \(attrs[.size] ?? "?") bytes to \(file.lastPathComponent)")
            if let captureDate {
                self.append("EXIF capture time: \(captureDate.formatted(date: .numeric, time: .standard))")
            } else {
                self.append("No EXIF capture time was found; automatic geotag matching is unavailable.")
            }
            self.lastResult = "Original JPEG downloaded"
        }
    }

    func saveDownloadedToPhotos() {
        guard let photo = downloadedPhoto else { append("No downloaded file yet."); return }
        guard !isSavingPhoto else { return }
        let match = geotagMatch(for: photo)
        isSavingPhoto = true
        Task {
            defer { isSavingPhoto = false }
            do {
                try await PhotosOriginalImporter.save(
                    fileURL: photo.fileURL,
                    originalFilename: photo.originalFilename,
                    captureDate: photo.captureDate,
                    location: match?.location
                )
                if let match {
                    append("Saved untouched original to Photos with location \(match.latitude), \(match.longitude).")
                    lastResult = "Photo saved with location"
                } else {
                    append("Saved untouched original to Photos without a matched location.")
                    lastResult = "Photo saved without location"
                }
            } catch {
                append("Photos import ERROR: \(error.localizedDescription)")
                lastResult = "Save to Photos failed"
            }
        }
    }

    func geotagMatch(for photo: DownloadedPhoto) -> GeotagMatch? {
        guard let captureDate = photo.captureDate else { return nil }
        return LocationTrackMatcher.match(
            captureDate: captureDate,
            samples: locationLogger.samples,
            cameraClockOffset: cameraClockOffsetMinutes * 60
        )
    }

    func clearLog() {
        log = ""
        persistLog()
        print("[GM1Sync] Log cleared")
    }

    private func run(_ operation: @escaping (LumixClient) async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        lastResult = "Running…"
        let client = self.client
        Task {
            defer { isRunning = false }
            do { try await operation(client) }
            catch {
                if error is URLError {
                    isCameraConnected = false
                    connectionStatusMessage = "Camera connection lost."
                }
                append("ERROR: \(error.localizedDescription)")
                lastResult = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func testContentInfo(_ client: LumixClient, label: String) async {
        do {
            let (response, info) = try await client.getContentInfo()
            append("\n--- \(label) ---")
            append("HTTP \(response.statusCode) \(response.url.absoluteString)")
            append("parsed: current=\(info.currentPosition.map(String.init) ?? "nil") total=\(info.totalContentNumber.map(String.init) ?? "nil") content=\(info.contentNumber.map(String.init) ?? "nil")")
            append(response.text)
        } catch { append("\n--- \(label) ERROR ---\n\(error.localizedDescription)") }
    }

    @discardableResult
    private func testBrowse(_ client: LumixClient, label: String) async -> Bool {
        do {
            let result = try await client.browseLast(5)
            logBrowseResult(result, label: label)
            return true
        } catch {
            append("\n--- \(label) ERROR ---\n\(error.localizedDescription)")
            return false
        }
    }

    private func testDirectBrowse(_ client: LumixClient, label: String) async -> Bool {
        do {
            let result = try await client.browse(start: 0, count: 5)
            logBrowseResult(result, label: label)
            return true
        } catch {
            append("\n--- \(label) ERROR ---\n\(error.localizedDescription)")
            return false
        }
    }

    private func logBrowseResult(_ result: LumixBrowseResult, label: String) {
        setResources(result.resources)
        append("\n--- \(label) ---")
        append("NumberReturned=\(result.numberReturned.map(String.init) ?? "nil") TotalMatches=\(result.totalMatches.map(String.init) ?? "nil") resources=\(result.resources.count)")
        for resource in result.resources {
            append("[\(resource.profileName ?? "unknown")] item=\(resource.itemID ?? "?") title=\(resource.title ?? "?")\n  \(resource.url.absoluteString)")
        }
        append("DIDL:\n\(result.didl)")
    }

    private func logResponse(_ label: String, _ response: LumixHTTPResponse) {
        append("\n--- \(label) ---")
        append("HTTP \(response.statusCode) \(response.url.absoluteString)\n\(response.text)")
    }

    private func setResources(_ value: [LumixResource]) { resources = value }
    private func append(_ text: String) {
        log += text + "\n"
        print("[GM1Sync] \(text)")
        persistLog()
    }

    private func persistLog() {
        do {
            try log.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[GM1Sync] Could not persist diagnostic log: \(error.localizedDescription)")
        }
    }
}
