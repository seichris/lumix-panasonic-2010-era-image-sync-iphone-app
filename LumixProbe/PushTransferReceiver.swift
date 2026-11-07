import Foundation

enum PushTransferReceiverEvent: Sendable {
    /// The camera read the device description: it has found this phone.
    case descriptionRequested
    /// The camera asked which upload profiles this receiver accepts.
    case uploadProfilesRequested
    case uploadAnnounced(token: String, request: PushTransferUploadRequest)
    case uploadStarted(token: String, filename: String)
    case uploadProgress(token: String, receivedBytes: Int64)
    case uploadCompleted(PushReceivedFile)
    case uploadFailed(token: String?, filename: String?, failure: PushUploadFailure)
    case unsupportedRequest(String)
}

/// The UPnP MediaServer the camera uploads to: device and service descriptions,
/// `X_GetDLNAUploadProfiles`, `CreateObject`, and one import URI per announced image.
///
/// Requests are routed on the HTTP server's queue; only the base URL is set from elsewhere.
final class PushTransferReceiver: PushHTTPRouting, @unchecked Sendable {
    struct Configuration: Sendable {
        var friendlyName: String
        var deviceUUID: String
        var uploadDirectory: URL
        var maximumUploadBytes: Int64 = 64 * 1_024 * 1_024
        var maximumSOAPBytes = 256 * 1_024
        /// Import URIs the camera has not used within this time are forgotten.
        var tokenLifetime: TimeInterval = 15 * 60
    }

    private let configuration: Configuration
    private let emit: @Sendable (PushTransferReceiverEvent) -> Void
    private let now: () -> Date
    private let baseURLLock = NSLock()
    private var storedBaseURL: URL?
    private var announcedUploads: [String: (request: PushTransferUploadRequest, createdAt: Date)] = [:]

    init(
        configuration: Configuration,
        now: @escaping () -> Date = Date.init,
        emit: @escaping @Sendable (PushTransferReceiverEvent) -> Void
    ) {
        self.configuration = configuration
        self.now = now
        self.emit = emit
    }

    /// The phone's address on the camera network, used in import URIs.
    func setBaseURL(_ url: URL) {
        baseURLLock.withLock { storedBaseURL = url }
    }

    private var baseURL: URL? { baseURLLock.withLock { storedBaseURL } }

    func route(_ head: PushHTTPRequestHead) -> PushHTTPRoute {
        switch (head.method, head.path) {
        case ("GET", PushTransferProtocol.descriptionPath), ("HEAD", PushTransferProtocol.descriptionPath):
            emit(.descriptionRequested)
            return .respond(.xml(PushTransferDocuments.deviceDescription(
                friendlyName: configuration.friendlyName,
                deviceUUID: configuration.deviceUUID
            )))
        case ("GET", PushTransferProtocol.serviceDescriptionPath):
            return .respond(.xml(PushTransferDocuments.serviceDescription))
        case ("POST", PushTransferProtocol.controlPath):
            let action = pushTransferSOAPAction(head.header("soapaction"))
            return .collect(limit: configuration.maximumSOAPBytes) { [weak self] body in
                self?.handleSOAP(action: action, body: body) ?? .empty(503, "Service Unavailable")
            }
        case (let method, let path) where (method == "POST" || method == "PUT")
            && path.hasPrefix(PushTransferProtocol.uploadPathPrefix):
            return routeUpload(token: String(path.dropFirst(PushTransferProtocol.uploadPathPrefix.count)))
        default:
            emit(.unsupportedRequest("\(head.method) \(head.path)"))
            return .respond(.empty(404, "Not Found"))
        }
    }

    private func handleSOAP(action: String?, body: Data) -> PushHTTPResponse {
        switch action {
        case "X_GetDLNAUploadProfiles":
            emit(.uploadProfilesRequested)
            return .xml(PushTransferDocuments.uploadProfilesResponse())
        case "CreateObject":
            guard let request = PushTransferUploadRequest.parseCreateObject(body) else {
                return .xml(PushTransferDocuments.soapFault(code: 402, description: "Invalid Args"),
                            status: 500, reason: "Internal Server Error")
            }
            guard let baseURL else {
                return .xml(PushTransferDocuments.soapFault(code: 501, description: "Action Failed"),
                            status: 500, reason: "Internal Server Error")
            }
            pruneExpiredUploads()
            let token = Self.makeToken()
            announcedUploads[token] = (request, now())
            let importURI = baseURL.appendingPathComponent("upload").appendingPathComponent(token)
            emit(.uploadAnnounced(token: token, request: request))
            return .xml(PushTransferDocuments.createObjectResponse(
                objectID: "push-\(token)", title: request.title, importURI: importURI
            ))
        default:
            emit(.unsupportedRequest("SOAP \(action ?? "without action")"))
            return .xml(PushTransferDocuments.soapFault(code: 401, description: "Invalid Action"),
                        status: 500, reason: "Internal Server Error")
        }
    }

    private func routeUpload(token: String) -> PushHTTPRoute {
        pruneExpiredUploads()
        // An import URI is single-use: a retry from the camera announces the image again.
        guard let announced = announcedUploads.removeValue(forKey: token) else {
            emit(.uploadFailed(token: token, filename: nil, failure: .malformedFraming))
            return .respond(.empty(404, "Not Found"))
        }
        let filename = announced.request.filename
        let emit = self.emit
        do {
            let sink = try PushUploadFileSink(
                token: token,
                filename: filename,
                declaredSize: announced.request.declaredSize,
                directory: configuration.uploadDirectory,
                maximumBytes: configuration.maximumUploadBytes,
                onProgress: { emit(.uploadProgress(token: token, receivedBytes: $0)) },
                onComplete: { emit(.uploadCompleted($0)) },
                onFailure: { emit(.uploadFailed(token: token, filename: filename, failure: $0)) }
            )
            emit(.uploadStarted(token: token, filename: filename))
            return .stream(sink)
        } catch {
            emit(.uploadFailed(token: token, filename: filename,
                               failure: error as? PushUploadFailure ?? .storage(error.localizedDescription)))
            return .respond(.empty(500, "Upload Failed"))
        }
    }

    private func pruneExpiredUploads() {
        let cutoff = now().addingTimeInterval(-configuration.tokenLifetime)
        announcedUploads = announcedUploads.filter { $0.value.createdAt >= cutoff }
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    }
}
