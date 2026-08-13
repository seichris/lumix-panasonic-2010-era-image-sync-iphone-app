import Foundation
import Photos

@MainActor
final class ProbeViewModel: ObservableObject {
    @Published var host = "192.168.54.1"
    @Published var log = "Join the GM1S Wi-Fi network, then probe the camera.\n"
    @Published var isRunning = false
    @Published var resources: [LumixResource] = []
    @Published var downloadedFile: URL?

    private var client: LumixClient { LumixClient(host: host.trimmingCharacters(in: .whitespacesAndNewlines)) }

    func probeState() { run { client in try await self.logResponse("getstate", client.getState()) } }
    func requestAccess() { run { client in try await self.logResponse("req_acc", client.requestAccess()) } }

    func runFullProbe() {
        run { client in
            await self.append("=== FULL PROBE ===")
            try await self.logResponse("1 current getstate", client.getState())

            do { try await self.logResponse("2 req_acc", client.requestAccess()) }
            catch { await self.append("2 req_acc ERROR (may already be authorized): \(error.localizedDescription)") }

            await self.testContentInfo(client, label: "3 content info in CURRENT state")

            do { try await self.logResponse("4 switch recmode", client.setRecordMode()) }
            catch { await self.append("4 recmode ERROR: \(error.localizedDescription)") }
            await self.testContentInfo(client, label: "5 content info in RECORD state")
            await self.testBrowse(client, label: "6 ContentDirectory browse in RECORD state")

            do { try await self.logResponse("7 switch playmode", client.setPlayMode()) }
            catch { await self.append("7 playmode ERROR: \(error.localizedDescription)") }
            await self.testContentInfo(client, label: "8 content info in PLAY state")
            await self.testBrowse(client, label: "9 final five records in PLAY state")

            await self.append("=== PROBE COMPLETE ===")
        }
    }

    func browseLastFive() {
        run { client in await self.testBrowse(client, label: "manual final five") }
    }

    func downloadFirstOriginal() {
        run { client in
            var candidates = self.resources.filter(\.isOriginalJPEG)
            if candidates.isEmpty {
                let result = try await client.browseLast(5)
                await self.setResources(result.resources)
                candidates = result.resources.filter(\.isOriginalJPEG)
            }
            guard let original = candidates.last else { throw LumixError.noOriginalJPEG }
            await self.append("Downloading CAM_ORG: \(original.url.absoluteString)")
            let file = try await client.download(original)
            await MainActor.run { self.downloadedFile = file }
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            await self.append("Downloaded \(attrs[.size] ?? "?") bytes to \(file.lastPathComponent)")
        }
    }

    func saveDownloadedToPhotos() {
        guard let file = downloadedFile else { append("No downloaded file yet."); return }
        Task {
            do {
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    append("Photos permission denied: \(status.rawValue)")
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: file, options: nil)
                }
                append("Saved untouched downloaded file to Photos.")
            } catch { append("Photos import ERROR: \(error.localizedDescription)") }
        }
    }

    func clearLog() { log = "" }

    private func run(_ operation: @escaping (LumixClient) async throws -> Void) {
        guard !isRunning else { return }
        isRunning = true
        let client = self.client
        Task {
            defer { isRunning = false }
            do { try await operation(client) }
            catch { append("ERROR: \(error.localizedDescription)") }
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

    private func testBrowse(_ client: LumixClient, label: String) async {
        do {
            let result = try await client.browseLast(5)
            setResources(result.resources)
            append("\n--- \(label) ---")
            append("NumberReturned=\(result.numberReturned.map(String.init) ?? "nil") TotalMatches=\(result.totalMatches.map(String.init) ?? "nil") resources=\(result.resources.count)")
            for resource in result.resources {
                append("[\(resource.profileName ?? "unknown")] item=\(resource.itemID ?? "?") title=\(resource.title ?? "?")\n  \(resource.url.absoluteString)")
            }
            append("DIDL:\n\(result.didl)")
        } catch { append("\n--- \(label) ERROR ---\n\(error.localizedDescription)") }
    }

    private func logResponse(_ label: String, _ pending: @autoclosure () async throws -> LumixHTTPResponse) async throws {
        let response = try await pending()
        append("\n--- \(label) ---")
        append("HTTP \(response.statusCode) \(response.url.absoluteString)\n\(response.text)")
    }

    private func setResources(_ value: [LumixResource]) { resources = value }
    private func append(_ text: String) { log += text + "\n" }
}
