import Foundation
import Network

struct CameraPlaybackDiagnosticSnapshot: Sendable {
    let failureSummary: String?
    let report: String
}

protocol CameraPlaybackSession: Sendable {
    func start() async throws -> URL
    func stop() async
    func diagnostics() async -> CameraPlaybackDiagnosticSnapshot?
}

extension CameraPlaybackSession {
    func diagnostics() async -> CameraPlaybackDiagnosticSnapshot? { nil }
}

actor DownloadedCameraPlaybackSession: CameraPlaybackSession {
    private let download: @Sendable () async throws -> URL
    private var fileURL: URL?

    init(download: @escaping @Sendable () async throws -> URL) {
        self.download = download
    }

    func start() async throws -> URL {
        if let fileURL { return fileURL }
        let downloaded = try await download()
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        fileURL = downloaded
        return downloaded
    }

    func stop() async {
        guard let fileURL else { return }
        self.fileURL = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

actor PanasonicAVCHDPlaybackSession: CameraPlaybackSession {
    private let resource: LumixResource
    private let availableResources: [LumixResource]
    private var proxy: PanasonicLoopbackProxy?

    init(resource: LumixResource, availableResources: [LumixResource]) {
        self.resource = resource
        self.availableResources = availableResources
    }

    func start() async throws -> URL {
        if let proxy, let localURL = proxy.localURL { return localURL }
        let proxy = PanasonicLoopbackProxy(
            resource: resource,
            availableResources: availableResources
        )
        let localURL = try await proxy.start()
        self.proxy = proxy
        return localURL
    }

    func stop() async {
        guard let proxy else { return }
        self.proxy = nil
        await proxy.stop()
    }

    func diagnostics() async -> CameraPlaybackDiagnosticSnapshot? {
        guard let proxy else { return nil }
        return await proxy.diagnostics()
    }
}

private final class PanasonicLoopbackProxy: @unchecked Sendable {
    private let resource: LumixResource
    private let remoteURL: URL
    private let queue = DispatchQueue(label: "com.web3.gm1sync.avchd-loopback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private(set) var localURL: URL?
    private var diagnosticEvents: [String]
    private var lastCameraStatusLine: String?

    init(resource: LumixResource, availableResources: [LumixResource]) {
        self.resource = resource
        remoteURL = resource.url
        diagnosticEvents = [
            "GM1 Sync AVCHD playback diagnostic",
            "Profile: \(resource.profileName ?? "unknown")",
            "Role: \(resource.role.rawValue)",
            "Resolution: \(resource.resolutionWidth.map(String.init) ?? "?")x\(resource.resolutionHeight.map(String.init) ?? "?")",
            "Duration: \(resource.duration.map { String(format: "%.3f", $0) } ?? "unknown") seconds",
            "Advertised URL: \(resource.url.absoluteString)",
            "Available item resources: \(availableResources.count)"
        ]
        diagnosticEvents.append(contentsOf: availableResources.enumerated().map { index, candidate in
            "  [\(index)] profile=\(candidate.profileName ?? "unknown") role=\(candidate.role.rawValue) " +
                "resolution=\(candidate.resolutionWidth.map(String.init) ?? "?")x\(candidate.resolutionHeight.map(String.init) ?? "?") " +
                "url=\(candidate.url.absoluteString)"
        })
    }

    func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        self.startContinuation = continuation
                        listener.newConnectionHandler = { [weak self] connection in
                            self?.accept(connection)
                        }
                        listener.stateUpdateHandler = { [weak self] state in
                            self?.handleListenerState(state)
                        }
                        listener.start(queue: self.queue)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.stopSoon()
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.stopLocked(error: CancellationError())
                continuation.resume()
            }
        }
    }

    func diagnostics() async -> CameraPlaybackDiagnosticSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: CameraPlaybackDiagnosticSnapshot(
                        failureSummary: nil,
                        report: "Playback diagnostics are no longer available."
                    ))
                    return
                }
                let summary: String?
                if self.lastCameraStatusLine?.contains(" 404 ") == true {
                    summary = "The camera returned HTTP 404 for the selected \(self.resource.role == .avchdPlayback360 ? "360p playback stream" : "video stream")."
                } else if let status = self.lastCameraStatusLine {
                    summary = "The camera returned \(status)."
                } else {
                    summary = nil
                }
                continuation.resume(returning: CameraPlaybackDiagnosticSnapshot(
                    failureSummary: summary,
                    report: self.diagnosticEvents.joined(separator: "\n")
                ))
            }
        }
    }

    private func stopSoon() {
        queue.async { [weak self] in
            self?.stopLocked(error: CancellationError())
        }
    }

    private func stopLocked(error: Error) {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        localURL = nil
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: error)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/temp.ts") else {
                stopLocked(error: LoopbackProxyError.missingListenerPort)
                return
            }
            localURL = url
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(returning: url)
            }
        case let .failed(error):
            stopLocked(error: error)
        case .cancelled:
            if let startContinuation {
                self.startContinuation = nil
                startContinuation.resume(throwing: CancellationError())
            }
        default:
            break
        }
    }

    private func accept(_ local: NWConnection) {
        let localID = UUID()
        connections[localID] = local
        local.stateUpdateHandler = { [weak self, weak local] state in
            guard let self, let local else { return }
            switch state {
            case .ready:
                self.receiveRequest(from: local, id: localID, buffer: Data())
            case .failed, .cancelled:
                self.connections[localID] = nil
            default:
                break
            }
        }
        local.start(queue: queue)
    }

    private func receiveRequest(from local: NWConnection, id: UUID, buffer: Data) {
        local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak local] data, _, isComplete, error in
            guard let self, let local else { return }
            if let error {
                self.finish(local, id: id, error: error)
                return
            }

            var request = buffer
            if let data { request.append(data) }
            if let boundary = request.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = request[..<boundary.lowerBound]
                self.openRemote(for: String(decoding: headerData, as: UTF8.self), local: local, localID: id)
                return
            }
            if request.count >= 64 * 1024 {
                self.sendError(431, reason: "Request Header Fields Too Large", to: local, id: id)
                return
            }
            if isComplete {
                self.sendError(400, reason: "Bad Request", to: local, id: id)
                return
            }
            self.receiveRequest(from: local, id: id, buffer: request)
        }
    }

    private func openRemote(for localHeaders: String, local: NWConnection, localID: UUID) {
        let lines = localHeaders.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("GET ") == true else {
            sendError(405, reason: "Method Not Allowed", to: local, id: localID)
            return
        }
        guard remoteURL.scheme == "http", let host = remoteURL.host else {
            sendError(502, reason: "Bad Gateway", to: local, id: localID)
            return
        }
        let portValue = remoteURL.port ?? 80
        guard let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            sendError(502, reason: "Bad Gateway", to: local, id: localID)
            return
        }

        let range = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        let remoteRange = PanasonicDLNARemoteRange.fromLocalPlayerRange(range)
        let request: String
        do {
            request = try LumixMediaHTTPRequest.make(
                for: remoteURL,
                style: .panasonicDLNAInitial,
                rangeHeader: remoteRange
            )
        } catch {
            sendError(502, reason: "Bad Gateway", to: local, id: localID)
            return
        }
        diagnosticEvents.append("Local AVPlayer range: \(range ?? "none")")
        diagnosticEvents.append("Camera range after Panasonic seek translation: \(remoteRange ?? "none")")
        diagnosticEvents.append("Camera request: \(request.components(separatedBy: "\r\n").first ?? "GET")")
        diagnosticEvents.append("Camera request mode: \(remoteRange == nil ? "Panasonic initial plain GET" : "Panasonic byte range")")

        let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let remoteID = UUID()
        connections[remoteID] = remote
        remote.stateUpdateHandler = { [weak self, weak remote, weak local] state in
            guard let self, let remote, let local else { return }
            switch state {
            case .ready:
                remote.send(
                    content: Data(request.utf8),
                    contentContext: .defaultMessage,
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if let error {
                            self.finish(remote, id: remoteID, error: error)
                            self.sendError(502, reason: "Bad Gateway", to: local, id: localID)
                        } else {
                            self.receiveRemoteHeader(
                                from: remote,
                                remoteID: remoteID,
                                to: local,
                                localID: localID,
                                buffer: Data()
                            )
                        }
                    }
                )
            case let .failed(error):
                self.finish(remote, id: remoteID, error: error)
                self.sendError(502, reason: "Bad Gateway", to: local, id: localID)
            case .cancelled:
                self.connections[remoteID] = nil
            default:
                break
            }
        }
        remote.start(queue: queue)
    }

    private func receiveRemoteHeader(
        from remote: NWConnection,
        remoteID: UUID,
        to local: NWConnection,
        localID: UUID,
        buffer: Data
    ) {
        remote.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak remote, weak local] data, _, isComplete, error in
            guard let self, let remote, let local else { return }
            if let error {
                self.finish(remote, id: remoteID, error: error)
                self.finish(local, id: localID, error: error)
                return
            }

            var response = buffer
            if let data { response.append(data) }
            if let boundary = response.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = boundary.upperBound
                let headerText = String(decoding: response[..<headerEnd], as: UTF8.self)
                self.recordCameraResponse(headerText)
                self.forward(
                    response,
                    remoteIsComplete: isComplete,
                    from: remote,
                    remoteID: remoteID,
                    to: local,
                    localID: localID
                )
                return
            }
            if response.count >= 64 * 1024 {
                self.diagnosticEvents.append("Camera response header exceeded 64 KiB.")
                self.finish(remote, id: remoteID)
                self.sendError(502, reason: "Bad Gateway", to: local, id: localID)
                return
            }
            if isComplete {
                self.diagnosticEvents.append("Camera closed before completing an HTTP response header.")
                self.finish(remote, id: remoteID)
                self.sendError(502, reason: "Bad Gateway", to: local, id: localID)
                return
            }
            self.receiveRemoteHeader(
                from: remote,
                remoteID: remoteID,
                to: local,
                localID: localID,
                buffer: response
            )
        }
    }

    private func recordCameraResponse(_ headerText: String) {
        let lines = headerText
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
        lastCameraStatusLine = lines.first
        diagnosticEvents.append("Camera response headers:")
        diagnosticEvents.append(contentsOf: lines)
        print("[GM1Sync] AVCHD camera response: \(lines.first ?? "invalid response")")
    }

    private func forward(
        _ data: Data,
        remoteIsComplete: Bool,
        from remote: NWConnection,
        remoteID: UUID,
        to local: NWConnection,
        localID: UUID
    ) {
        local.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: remoteIsComplete,
            completion: .contentProcessed { [weak self, weak remote, weak local] error in
                guard let self, let remote, let local else { return }
                if let error {
                    self.finish(remote, id: remoteID, error: error)
                    self.finish(local, id: localID, error: error)
                } else if remoteIsComplete {
                    self.finish(remote, id: remoteID)
                    self.finish(local, id: localID)
                } else {
                    self.relay(from: remote, remoteID: remoteID, to: local, localID: localID)
                }
            }
        )
    }

    private func relay(
        from remote: NWConnection,
        remoteID: UUID,
        to local: NWConnection,
        localID: UUID
    ) {
        remote.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak remote, weak local] data, _, isComplete, error in
            guard let self, let remote, let local else { return }
            if let error {
                self.finish(remote, id: remoteID, error: error)
                self.finish(local, id: localID, error: error)
                return
            }

            guard let data, !data.isEmpty else {
                if isComplete {
                    self.finish(remote, id: remoteID)
                    self.finish(local, id: localID)
                } else {
                    self.relay(from: remote, remoteID: remoteID, to: local, localID: localID)
                }
                return
            }

            local.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error {
                        self.finish(remote, id: remoteID, error: error)
                        self.finish(local, id: localID, error: error)
                    } else if isComplete {
                        self.finish(remote, id: remoteID)
                        self.finish(local, id: localID)
                    } else {
                        self.relay(from: remote, remoteID: remoteID, to: local, localID: localID)
                    }
                }
            )
        }
    }

    private func sendError(_ code: Int, reason: String, to connection: NWConnection, id: UUID) {
        let body = "\(code) \(reason)"
        let response = "HTTP/1.1 \(code) \(reason)\r\n" +
            "Content-Type: text/plain\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            body
        connection.send(
            content: Data(response.utf8),
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.finish(connection, id: id, error: error)
            }
        )
    }

    private func finish(_ connection: NWConnection, id: UUID, error: Error? = nil) {
        if let error {
            print("[GM1Sync] AVCHD proxy connection ended: \(error.localizedDescription)")
        }
        connections[id] = nil
        connection.cancel()
    }
}

private enum LoopbackProxyError: LocalizedError {
    case missingListenerPort

    var errorDescription: String? {
        "Could not create a local AVCHD playback endpoint."
    }
}
