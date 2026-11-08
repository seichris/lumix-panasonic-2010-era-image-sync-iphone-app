import Foundation
import ImageIO

extension CameraActivity {
    /// Receiving pushed photos. It reserves the camera without switching its mode, and
    /// it survives the Wi-Fi join that is part of the camera's own setup steps.
    static let pushTransfer = CameraActivity(
        id: "push-transfer", title: "Receiving photos while shooting", mode: nil, isBoundToConnection: false
    )
}

protocol PushTransferHTTPServing: AnyObject, Sendable {
    func start(preferredPorts: [UInt16]) async throws -> UInt16
    func stop()
}

protocol SSDPAnnouncing: AnyObject, Sendable {
    func start() throws
    func announceNow()
    func setInterval(_ seconds: TimeInterval)
    func stop(sayGoodbye: Bool)
}

extension PushTransferHTTPServer: PushTransferHTTPServing {}
extension SSDPAnnouncer: SSDPAnnouncing {}

struct PushTransferItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case announced
        case receiving(Int64)
        case saving
        case saved
        case duplicate
        case waitingForPhotosAccess
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .saved, .duplicate, .failed: return true
            default: return false
            }
        }
    }

    let id: String
    var filename: String
    var state: State
    var byteCount: Int64?
    var declaredSize: Int64?
    var pixelWidth: Int?
    var pixelHeight: Int?
    let createdAt: Date
}

struct PushTransferDependencies {
    var cameraHost: String
    var friendlyName = "Retro LUMIX Sync"
    var deviceUUID: String
    /// Received files wait here until Photos has saved them; they survive relaunches.
    var pendingDirectory: URL
    var incomingDirectory: URL
    var localAddress: (String) -> PushTransferNetwork.LocalAddress? = PushTransferNetwork.localAddress(towards:)
    var makeServer: @MainActor (PushTransferReceiver, String) -> any PushTransferHTTPServing = { receiver, cameraHost in
        PushTransferHTTPServer(allowedPeerHost: cameraHost, router: receiver)
    }
    var makeAnnouncer: @MainActor (String, String?, SSDPAdvertisement, @escaping @Sendable (SSDPAnnouncerEvent) -> Void) -> any SSDPAnnouncing = {
        SSDPAnnouncer(cameraHost: $0, localAddress: $1, advertisement: $2, emit: $3)
    }
    var registrationCamera: @MainActor () -> (any RemoteCameraControlling)?
    var importer: any CameraMediaImporting
    var history: CameraPushTransferHistory
    var locationSamples: @MainActor () -> [LocationSample] = { [] }
    var cameraClockOffset: @MainActor () -> TimeInterval = { 0 }
    var metadataReader: @Sendable (URL) -> PhotoOriginalMetadata = { PhotoOriginalMetadataReader.read(from: $0) }
    var preferredPorts: [UInt16] = [49152, 49153, 49154, 49155]
    var networkPollInterval: Duration = .seconds(2)
    var linkedAnnouncementInterval: TimeInterval = 15

    static func standard(
        cameraHost: String,
        importer: any CameraMediaImporting,
        history: CameraPushTransferHistory,
        registrationCamera: @escaping @MainActor () -> (any RemoteCameraControlling)?,
        locationSamples: @escaping @MainActor () -> [LocationSample],
        cameraClockOffset: @escaping @MainActor () -> TimeInterval
    ) -> PushTransferDependencies {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PushTransferDependencies(
            cameraHost: cameraHost,
            deviceUUID: SSDPAdvertisement.persistentDeviceUUID(),
            pendingDirectory: support.appendingPathComponent("PushTransfers/Pending", isDirectory: true),
            incomingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("PushTransfers", isDirectory: true),
            registrationCamera: registrationCamera,
            importer: importer,
            history: history,
            locationSamples: locationSamples,
            cameraClockOffset: cameraClockOffset
        )
    }
}

/// An explicit, foreground receiving session for Send Images While Recording.
///
/// iOS suspends the app when it leaves the foreground or the iPhone locks, so the
/// session tears the receiver down then and brings it back, re-announcing itself,
/// when the app returns. Received files are kept until Photos has saved them.
@MainActor
final class PushTransferSession: ObservableObject {
    enum Phase: Equatable, Sendable {
        case idle
        case waitingForCameraNetwork
        case starting
        case advertising
        case linked
        case paused
        case stopped
        case failed(String)

        var isActive: Bool {
            switch self {
            case .waitingForCameraNetwork, .starting, .advertising, .linked, .paused: return true
            default: return false
            }
        }
    }

    enum RegistrationResult: Equatable, Sendable {
        case accepted
        case awaitingApprovalOnCamera
        case refused(String)
        case noReply(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var items: [PushTransferItem] = []
    @Published private(set) var savedCount = 0
    @Published private(set) var multicastStatus: SSDPMulticastStatus = .unknown
    /// The camera's own SSDP search reached this iPhone. On a GM1S this is how the camera
    /// finds the receiver: the search arrives as multicast and the reply goes back as unicast.
    @Published private(set) var cameraSearched = false
    /// Receiving resumed after the app was away while the camera already knew it. A GM1S
    /// that tried to send meanwhile shows "Connection error" and stops sending.
    @Published private(set) var resumedAfterPause = false
    @Published private(set) var lastCameraContact: Date?
    @Published private(set) var registration: RegistrationResult?
    @Published private(set) var needsPhotosAccess = false
    @Published private(set) var pendingFileCount = 0
    @Published private(set) var localEndpoint: String?

    private let dependencies: PushTransferDependencies
    private let coordinator: CameraModeCoordinator
    private var lease: CameraActivityLease?
    private var server: (any PushTransferHTTPServing)?
    private var announcer: (any SSDPAnnouncing)?
    private var lastPort: UInt16?
    private var isInBackground = false
    private var networkWaitTask: Task<Void, Never>?
    private var networkWatchTask: Task<Void, Never>?
    private var importQueue: [URL] = []
    private var queuedFiles: Set<URL> = []
    private var isProcessingImports = false
    private var itemIDsByToken: [String: String] = [:]
    private var bringUpGeneration = 0
    /// Receiver and announcer events arrive on network queues; these relays deliver
    /// them to the main actor in their original order (announce → progress → complete).
    private let receiverEvents = OrderedMainActorRelay<PushTransferReceiverEvent>()
    private let announcerEvents = OrderedMainActorRelay<SSDPAnnouncerEvent>()

    init(dependencies: PushTransferDependencies, coordinator: CameraModeCoordinator) {
        self.dependencies = dependencies
        self.coordinator = coordinator
        receiverEvents.handler = { [weak self] in self?.handle($0) }
        announcerEvents.handler = { [weak self] in self?.handle($0) }
    }

    // MARK: Lifecycle

    func start() async {
        guard lease == nil else { return }
        do {
            lease = try await coordinator.beginExclusive(.pushTransfer)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        isInBackground = false
        restorePendingFiles()
        await bringUp()
        await processImports()
    }

    func stop() async {
        networkWaitTask?.cancel()
        networkWaitTask = nil
        tearDown(sayGoodbye: true)
        if let lease {
            coordinator.endExclusive(lease)
            self.lease = nil
        }
        phase = .stopped
        // Files already received are still saved; anything left stays pending for later.
        await processImports()
    }

    func setAppActive(_ isActive: Bool) async {
        guard lease != nil else { return }
        if isActive {
            guard isInBackground else { return }
            isInBackground = false
            if lastCameraContact != nil { resumedAfterPause = true }
            await bringUp()
            announcer?.announceNow()
            await processImports()
        } else {
            guard !isInBackground else { return }
            isInBackground = true
            networkWaitTask?.cancel()
            networkWaitTask = nil
            // Keep the camera's cached description valid: no byebye, and reuse the port later.
            tearDown(sayGoodbye: false)
            phase = .paused
        }
    }

    /// Retries files that Photos has not saved yet, for example after access was granted.
    func retryPendingSaves() async {
        needsPhotosAccess = false
        restorePendingFiles()
        await processImports()
    }

    // MARK: Receiver

    private func bringUp() async {
        bringUpGeneration += 1
        let generation = bringUpGeneration
        guard lease != nil, !isInBackground else { return }
        guard let local = dependencies.localAddress(dependencies.cameraHost) else {
            // Off the camera's network (for example after returning from the background):
            // the camera has to find this receiver again once the iPhone is back.
            forgetCameraContact()
            phase = .waitingForCameraNetwork
            waitForCameraNetwork(generation: generation)
            return
        }
        phase = .starting
        let relay = receiverEvents
        let receiver = PushTransferReceiver(
            configuration: .init(
                friendlyName: dependencies.friendlyName,
                deviceUUID: dependencies.deviceUUID,
                uploadDirectory: dependencies.incomingDirectory
            ),
            emit: { relay.post($0) }
        )
        let server = dependencies.makeServer(receiver, dependencies.cameraHost)
        let preferredPorts = (lastPort.map { [$0] } ?? []) + dependencies.preferredPorts
        let port: UInt16
        do {
            port = try await server.start(preferredPorts: preferredPorts)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard generation == bringUpGeneration, lease != nil, !isInBackground else {
            server.stop()
            return
        }
        lastPort = port
        let base = "http://\(local.address):\(port)"
        receiver.setBaseURL(URL(string: base)!)
        localEndpoint = base
        self.server = server

        let advertisement = SSDPAdvertisement(
            deviceUUID: dependencies.deviceUUID,
            location: URL(string: base + PushTransferProtocol.descriptionPath)!
        )
        let announcerRelay = announcerEvents
        let announcer = dependencies.makeAnnouncer(dependencies.cameraHost, local.address, advertisement) {
            announcerRelay.post($0)
        }
        do {
            try announcer.start()
            self.announcer = announcer
        } catch {
            server.stop()
            self.server = nil
            phase = .failed(error.localizedDescription)
            return
        }
        if lastCameraContact != nil {
            announcer.setInterval(dependencies.linkedAnnouncementInterval)
        }
        phase = lastCameraContact == nil ? .advertising : .linked
        watchCameraNetwork(advertisedAddress: local.address)
        await registerWithCamera()
    }

    private func tearDown(sayGoodbye: Bool) {
        bringUpGeneration += 1
        networkWatchTask?.cancel()
        networkWatchTask = nil
        announcer?.stop(sayGoodbye: sayGoodbye)
        announcer = nil
        server?.stop()
        server = nil
    }

    private func waitForCameraNetwork(generation: Int) {
        networkWaitTask?.cancel()
        let interval = dependencies.networkPollInterval
        networkWaitTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard generation == self.bringUpGeneration else { return }
                if self.dependencies.localAddress(self.dependencies.cameraHost) != nil {
                    await self.bringUp()
                    return
                }
            }
        }
    }

    /// Notices when the iPhone leaves the camera's network or gets a different address.
    /// The GM1S turns its Wi-Fi off after "Connection error" or "Connection failed"; the
    /// receiver then waits for the network and announces its new address when it returns.
    private func watchCameraNetwork(advertisedAddress: String) {
        networkWatchTask?.cancel()
        let generation = bringUpGeneration
        let interval = dependencies.networkPollInterval
        networkWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, generation == self.bringUpGeneration else { return }
                let current = self.dependencies.localAddress(self.dependencies.cameraHost)?.address
                if current != advertisedAddress {
                    self.cameraNetworkWasLost()
                    return
                }
            }
        }
    }

    private func cameraNetworkWasLost() {
        // The camera forgets this receiver when its Wi-Fi goes down, so it has to find it again.
        tearDown(sayGoodbye: false)
        forgetCameraContact()
        phase = .waitingForCameraNetwork
        waitForCameraNetwork(generation: bringUpGeneration)
    }

    private func forgetCameraContact() {
        lastCameraContact = nil
        cameraSearched = false
        resumedAfterPause = false
    }

    /// Announces this phone to the camera as Shutterlink does; the camera then lists
    /// it as a destination. A failure is reported but does not stop the advertising.
    private func registerWithCamera() async {
        guard let camera = dependencies.registrationCamera() else { return }
        do {
            let reply = try await camera.send(
                .requestAccess(identifier: "0", clientName: dependencies.friendlyName),
                busyRetries: 2,
                busyDelay: .milliseconds(500),
                timeoutInterval: 5
            )
            if reply.isOK {
                registration = .accepted
            } else if reply.isAwaitingCameraApproval {
                registration = .awaitingApprovalOnCamera
            } else {
                registration = .refused(LumixResultCode.message(for: reply.result))
            }
        } catch {
            registration = .noReply(error.localizedDescription)
        }
    }

    private func handle(_ event: SSDPAnnouncerEvent) {
        switch event {
        case .cameraResponded:
            // The camera's own media server answering a search is not a sign that it found this iPhone.
            break
        case .cameraSearched:
            cameraSearched = true
            noteCameraContact()
        case let .multicastStatus(status):
            multicastStatus = status
        }
    }

    private func handle(_ event: PushTransferReceiverEvent) {
        switch event {
        case .descriptionRequested, .uploadProfilesRequested:
            noteCameraContact()
        case let .uploadAnnounced(token, request):
            noteCameraContact()
            let id = UUID().uuidString
            itemIDsByToken[token] = id
            items.insert(PushTransferItem(id: id, filename: request.filename, state: .announced,
                                          declaredSize: request.declaredSize, createdAt: Date()), at: 0)
            trimItems()
        case let .uploadStarted(token, _):
            updateItem(token: token) { $0.state = .receiving(0) }
        case let .uploadProgress(token, bytes):
            updateItem(token: token) { $0.state = .receiving(bytes) }
        case let .uploadCompleted(file):
            updateItem(token: file.token) {
                $0.state = .saving
                $0.byteCount = file.byteCount
            }
            do {
                let pending = try moveToPending(file.fileURL, filename: file.filename, itemID: itemIDsByToken[file.token])
                enqueue(pending)
            } catch {
                updateItem(token: file.token) { $0.state = .failed("The file could not be kept: \(error.localizedDescription)") }
            }
            Task { await processImports() }
        case let .uploadFailed(token, filename, failure):
            if let token, itemIDsByToken[token] != nil {
                updateItem(token: token) { $0.state = .failed(failure.message) }
            } else {
                items.insert(PushTransferItem(id: UUID().uuidString, filename: filename ?? "Unknown file",
                                              state: .failed(failure.message), createdAt: Date()), at: 0)
                trimItems()
            }
        case let .unsupportedRequest(description):
            print("[GM1Sync] Transfer receiver ignored \(description)")
        }
    }

    private func noteCameraContact() {
        lastCameraContact = Date()
        resumedAfterPause = false
        if phase == .advertising {
            phase = .linked
            announcer?.setInterval(dependencies.linkedAnnouncementInterval)
        }
    }

    // MARK: Photos

    private func enqueue(_ fileURL: URL) {
        guard queuedFiles.insert(fileURL).inserted else { return }
        importQueue.append(fileURL)
        pendingFileCount = pendingFiles().count
    }

    private func processImports() async {
        guard !isProcessingImports else { return }
        isProcessingImports = true
        defer {
            isProcessingImports = false
            pendingFileCount = pendingFiles().count
        }
        while !importQueue.isEmpty {
            let fileURL = importQueue.removeFirst()
            await importPendingFile(fileURL)
            queuedFiles.remove(fileURL)
        }
    }

    private func importPendingFile(_ fileURL: URL) async {
        let (itemID, filename) = Self.parsePendingName(fileURL.lastPathComponent)
        let resolvedID = itemID ?? fileURL.lastPathComponent
        if !items.contains(where: { $0.id == resolvedID }) {
            items.insert(PushTransferItem(id: resolvedID, filename: filename, state: .saving, createdAt: Date()), at: 0)
            trimItems()
        }
        updateItem(id: resolvedID) { $0.state = .saving }

        let reader = dependencies.metadataReader
        let inspection = await Task.detached(priority: .userInitiated) { () -> (String, Int64, PhotoOriginalMetadata, (Int, Int)?)? in
            guard let hash = try? PushReceivedFile.sha256(of: fileURL),
                  let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value else {
                return nil
            }
            return (hash, size, reader(fileURL), Self.pixelSize(of: fileURL))
        }.value
        guard let (sha256, byteCount, metadata, pixels) = inspection else {
            updateItem(id: resolvedID) { $0.state = .failed("The received file could not be read.") }
            return
        }
        updateItem(id: resolvedID) {
            $0.byteCount = byteCount
            $0.pixelWidth = pixels?.0
            $0.pixelHeight = pixels?.1
        }

        // The camera may deliver the same image again after a dropped connection.
        if dependencies.history.savedRecord(sha256: sha256) != nil {
            try? FileManager.default.removeItem(at: fileURL)
            updateItem(id: resolvedID) { $0.state = .duplicate }
            return
        }

        let geotag: GeotagMatch?
        if metadata.embeddedLocation == nil, let captureDate = metadata.captureDate {
            geotag = LocationTrackMatcher.match(
                captureDate: captureDate,
                samples: dependencies.locationSamples(),
                cameraClockOffset: dependencies.cameraClockOffset()
            )
        } else {
            geotag = nil
        }
        let media = DownloadedCameraMedia(
            variant: .jpeg,
            resources: [.init(fileURL: fileURL, originalFilename: filename, role: .photo)],
            captureDate: metadata.captureDate,
            embeddedLocation: metadata.embeddedLocation
        )
        do {
            try await dependencies.importer.save(media, geotag: geotag)
        } catch CameraMediaImportError.permissionDenied {
            needsPhotosAccess = true
            updateItem(id: resolvedID) { $0.state = .waitingForPhotosAccess }
            return
        } catch {
            updateItem(id: resolvedID) { $0.state = .failed("Photos could not save it: \(error.localizedDescription)") }
            return
        }
        // Only now, after Photos has the asset, is the transfer reported as saved.
        dependencies.history.append(CameraPushTransferRecord(
            filename: filename, byteCount: byteCount, sha256: sha256,
            pixelWidth: pixels?.0, pixelHeight: pixels?.1, receivedAt: Date(),
            savedToPhotosAt: Date(), source: dependencies.cameraHost
        ))
        try? FileManager.default.removeItem(at: fileURL)
        savedCount += 1
        updateItem(id: resolvedID) { $0.state = .saved }
    }

    // MARK: Pending files

    private func moveToPending(_ fileURL: URL, filename: String, itemID: String?) throws -> URL {
        try FileManager.default.createDirectory(at: dependencies.pendingDirectory, withIntermediateDirectories: true)
        let destination = dependencies.pendingDirectory.appendingPathComponent("\(itemID ?? UUID().uuidString)__\(filename)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    private func restorePendingFiles() {
        for file in pendingFiles() { enqueue(file) }
    }

    private func pendingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dependencies.pendingDirectory, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return files.filter { $0.lastPathComponent.contains("__") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated static func parsePendingName(_ name: String) -> (itemID: String?, filename: String) {
        guard let range = name.range(of: "__") else { return (nil, name) }
        let id = String(name[..<range.lowerBound])
        let filename = String(name[range.upperBound...])
        return (id.isEmpty ? nil : id, filename.isEmpty ? "LUMIX.JPG" : filename)
    }

    nonisolated static func pixelSize(of fileURL: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    // MARK: Items

    private func updateItem(token: String, _ change: (inout PushTransferItem) -> Void) {
        guard let id = itemIDsByToken[token] else { return }
        updateItem(id: id, change)
    }

    private func updateItem(id: String, _ change: (inout PushTransferItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func trimItems() {
        if items.count > 200 { items.removeLast(items.count - 200) }
    }
}

/// Queues events from any thread and handles them on the main actor in FIFO order.
final class OrderedMainActorRelay<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Event] = []
    private var isScheduled = false
    @MainActor var handler: ((Event) -> Void)?

    func post(_ event: Event) {
        let shouldSchedule: Bool = lock.withLock {
            queue.append(event)
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor in self.drain() }
    }

    @MainActor
    private func drain() {
        while true {
            let batch: [Event] = lock.withLock {
                let events = queue
                queue = []
                if events.isEmpty { isScheduled = false }
                return events
            }
            guard !batch.isEmpty else { return }
            for event in batch { handler?(event) }
        }
    }
}
