import Foundation

/// UI-test fixture: plays a camera's Send Images While Recording exchange through the
/// real receiver and HTTP parser, without opening any socket.
final class DemoPushTransferServer: PushTransferHTTPServing, @unchecked Sendable {
    private let receiver: PushTransferReceiver
    private let lock = NSLock()
    private var simulation: Task<Void, Never>?

    init(receiver: PushTransferReceiver) {
        self.receiver = receiver
    }

    func start(preferredPorts: [UInt16]) async throws -> UInt16 {
        let receiver = self.receiver
        let task = Task.detached {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            _ = Self.exchange(receiver, "GET \(PushTransferProtocol.descriptionPath) HTTP/1.1\r\nHost: phone\r\n\r\n")
            _ = Self.exchange(receiver, Self.soapRequest(action: "X_GetDLNAUploadProfiles", body: "<GetUploadProfiles></GetUploadProfiles>"))
            let didl = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">" +
                "<item id=\"\" parentID=\"0\" restricted=\"0\"><dc:title>P1000001</dc:title>" +
                "<res protocolInfo=\"*:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG\"></res></item></DIDL-Lite>"
            let response = Self.exchange(receiver, Self.soapRequest(
                action: "CreateObject",
                body: "<ContainerID>DLNA.ORG_AnyContainer</ContainerID><Elements>\(didl.xmlEscapedForPush)</Elements>"
            ))
            guard let token = response.firstCapture(of: "upload/([0-9a-f]+)"),
                  let jpeg = LumixLiveViewPacketBuilder.syntheticJPEG(width: 640, height: 480, phase: 0.6) else { return }
            try? await Task.sleep(for: .milliseconds(400))
            let half = jpeg.count / 2
            var upload = Data("POST /upload/\(token) HTTP/1.1\r\nHost: phone\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
            for chunk in [jpeg.prefix(half), jpeg.suffix(from: half)] {
                upload.append(Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8))
                upload.append(Data(chunk))
                upload.append(Data("\r\n".utf8))
            }
            upload.append(Data("0\r\n\r\n".utf8))
            _ = Self.exchange(receiver, upload)
        }
        lock.withLock { simulation = task }
        return preferredPorts.first ?? 49152
    }

    func stop() {
        lock.withLock { simulation }?.cancel()
    }

    private static func exchange(_ receiver: PushTransferReceiver, _ request: String) -> String {
        exchange(receiver, Data(request.utf8))
    }

    private static func exchange(_ receiver: PushTransferReceiver, _ request: Data) -> String {
        let processor = PushHTTPConnectionProcessor(router: receiver)
        let outputs = processor.receive(request)
        var response = Data()
        for case let .send(data) in outputs { response.append(data) }
        return String(decoding: response, as: UTF8.self)
    }

    private static func soapRequest(action: String, body: String) -> String {
        let envelope = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>" +
            "<u:\(action) xmlns:u=\"\(PushTransferProtocol.contentDirectoryType)\">\(body)</u:\(action)></s:Body></s:Envelope>"
        return "POST \(PushTransferProtocol.controlPath) HTTP/1.1\r\nHost: phone\r\n" +
            "SOAPACTION: \"\(PushTransferProtocol.contentDirectoryType)#\(action)\"\r\n" +
            "Content-Type: text/xml; charset=\"utf-8\"\r\nContent-Length: \(Data(envelope.utf8).count)\r\n\r\n" + envelope
    }
}

/// UI-test fixture: a camera network the iPhone is not on until the receiving screen joins it.
final class DemoCameraNetwork: @unchecked Sendable {
    static let name = "GM1S-DEMO"
    private let lock = NSLock()
    private var joined = false

    var address: PushTransferNetwork.LocalAddress? {
        lock.withLock { joined } ? PushTransferNetwork.LocalAddress(address: "192.168.54.10", interface: "en0") : nil
    }

    func join() async throws {
        try await Task.sleep(for: .milliseconds(300))
        lock.withLock { joined = true }
    }
}

final class DemoSSDPAnnouncer: SSDPAnnouncing, @unchecked Sendable {
    private let emit: @Sendable (SSDPAnnouncerEvent) -> Void

    init(emit: @escaping @Sendable (SSDPAnnouncerEvent) -> Void) {
        self.emit = emit
    }

    func start() throws {
        emit(.multicastStatus(.blocked("The demo camera does not use multicast.")))
        emit(.cameraSearched(SSDPMessage(
            startLine: "M-SEARCH * HTTP/1.1",
            headers: ["ST": PushTransferProtocol.mediaServerType, "MX": "5"]
        )))
    }

    func announceNow() {}
    func setInterval(_ seconds: TimeInterval) {}
    func stop(sayGoodbye: Bool) {}
}

/// Accepts every save without touching the Photos library.
struct DemoPushTransferImporter: CameraMediaImporting {
    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        try await Task.sleep(for: .milliseconds(200))
    }
}
