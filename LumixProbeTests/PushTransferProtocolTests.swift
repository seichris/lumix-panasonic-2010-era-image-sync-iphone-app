import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import GM1Sync

final class PushTransferProtocolTests: XCTestCase {
    private var directory: URL!
    private var jpeg: Data!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PushTransferTests-\(UUID().uuidString)")
        jpeg = try XCTUnwrap(LumixLiveViewPacketBuilder.syntheticJPEG(width: 64, height: 48))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: SSDP and descriptions

    func testNotificationsAdvertiseEveryTypeWithTheReceiverLocation() throws {
        let advertisement = SSDPAdvertisement(
            deviceUUID: "4D454930-0100-1000-8001-0123456789AB",
            location: URL(string: "http://192.168.54.10:49152/dms/ddd.xml")!
        )
        let alive = advertisement.notifications(alive: true).compactMap(SSDPMessage.parse)
        XCTAssertEqual(alive.count, 5)
        XCTAssertEqual(Set(alive.compactMap { $0.header("NT") }), [
            "uuid:4D454930-0100-1000-8001-0123456789AB", "upnp:rootdevice",
            "urn:schemas-upnp-org:device:MediaServer:1",
            "urn:schemas-upnp-org:service:ContentDirectory:1",
            "urn:schemas-upnp-org:service:ConnectionManager:1"
        ])
        XCTAssertTrue(alive.allSatisfy { $0.header("LOCATION") == "http://192.168.54.10:49152/dms/ddd.xml" })
        XCTAssertTrue(alive.allSatisfy { $0.header("NTS") == "ssdp:alive" })

        let goodbye = advertisement.notifications(alive: false).compactMap(SSDPMessage.parse)
        XCTAssertTrue(goodbye.allSatisfy { $0.header("NTS") == "ssdp:byebye" && $0.header("LOCATION") == nil })

        let reply = try XCTUnwrap(advertisement.searchResponse(for: "urn:schemas-upnp-org:device:MediaServer:1"))
        let parsed = try XCTUnwrap(SSDPMessage.parse(reply))
        XCTAssertTrue(parsed.isSearchResponse)
        XCTAssertEqual(parsed.header("USN"), "uuid:4D454930-0100-1000-8001-0123456789AB::urn:schemas-upnp-org:device:MediaServer:1")
        XCTAssertNil(advertisement.searchResponse(for: "urn:schemas-upnp-org:device:MediaRenderer:1"))
        XCTAssertTrue(try XCTUnwrap(SSDPMessage.parse(SSDPAdvertisement.cameraSearch())).isSearch)
    }

    func testDeviceUUIDIsStablePerInstallation() {
        let defaults = UserDefaults(suiteName: "PushTransferTests-\(UUID().uuidString)")!
        let first = SSDPAdvertisement.persistentDeviceUUID(defaults: defaults)
        XCTAssertTrue(first.hasPrefix("4D454930-0100-1000-8001-"))
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(SSDPAdvertisement.persistentDeviceUUID(defaults: defaults), first)
    }

    func testDeviceDescriptionAdvertisesImageUploadAndEscapesTheName() throws {
        let description = PushTransferDocuments.deviceDescription(friendlyName: "Chris & Co <iPhone>", deviceUUID: "UUID-1")
        let root = try XCTUnwrap(LumixXML.parse(description))
        XCTAssertEqual(root.firstDescendant(named: "friendlyName")?.trimmedText, "Chris & Co <iPhone>")
        XCTAssertEqual(root.firstDescendant(named: "X_DLNACAP")?.trimmedText, "image-upload")
        XCTAssertEqual(root.firstDescendant(named: "deviceType")?.trimmedText, "urn:schemas-upnp-org:device:MediaServer:1")
        XCTAssertEqual(root.firstDescendant(named: "controlURL")?.trimmedText, "/dms/control_0")
        XCTAssertNotNil(LumixXML.parse(PushTransferDocuments.serviceDescription))
    }

    func testCreateObjectRequestYieldsASafeFilenameAndDeclaredSize() throws {
        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item id=\"\" parentID=\"0\">" +
            "<dc:title>P1030516</dc:title><res size=\"6123456\" resolution=\"4592x3448\" " +
            "protocolInfo=\"*:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG\"></res></item></DIDL-Lite>"
        let body = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:CreateObject>" +
            "<ContainerID>0</ContainerID><Elements>\(didl.xmlEscapedForPush)</Elements></u:CreateObject></s:Body></s:Envelope>"
        let request = try XCTUnwrap(PushTransferUploadRequest.parseCreateObject(Data(body.utf8)))
        XCTAssertEqual(request.title, "P1030516")
        XCTAssertEqual(request.filename, "P1030516.JPG")
        XCTAssertEqual(request.declaredSize, 6_123_456)
        XCTAssertEqual(request.declaredResolution, "4592x3448")

        XCTAssertEqual(PushTransferUploadRequest(title: "../../etc/passwd").filename, "etcpasswd.JPG")
        XCTAssertEqual(PushTransferUploadRequest(title: "P1000002.jpg").filename, "P1000002.jpg")
        XCTAssertEqual(PushTransferUploadRequest(title: "///").filename, "LUMIX.JPG")
        XCTAssertNil(PushTransferUploadRequest.parseCreateObject(Data("<s:Envelope/>".utf8)))
        XCTAssertEqual(pushTransferSOAPAction("\"urn:schemas-upnp-org:service:ContentDirectory:1#CreateObject\""), "CreateObject")
        XCTAssertNil(pushTransferSOAPAction(nil))
    }

    // MARK: HTTP framing

    func testContentLengthBodySplitAcrossReadsIsCollected() throws {
        let router = StubRouter(route: .collect(limit: 64) { body in .xml("<ok>\(body.count)</ok>") })
        let processor = PushHTTPConnectionProcessor(router: router)
        XCTAssertTrue(processor.receive(Data("POST /x HTTP/1.1\r\nContent-Le".utf8)).isEmpty)
        XCTAssertTrue(processor.receive(Data("ngth: 10\r\n\r\n01234".utf8)).isEmpty)
        let outputs = processor.receive(Data("56789".utf8))
        XCTAssertEqual(outputs.last, .close)
        let response = try responseText(outputs)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(response.contains("<ok>10</ok>"))
        XCTAssertTrue(response.contains("Connection: close"))
        XCTAssertTrue(processor.isFinished)
    }

    func testChunkedDecoderHandlesExtensionsTrailersAndByteByByteDelivery() throws {
        let encoded = Data("4;name=value\r\nWiki\r\n5\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n".utf8)
        var decoder = PushChunkedDecoder()
        var payload = Data()
        var pending = Data()
        for byte in encoded {
            pending.append(byte)
            payload.append(try decoder.decode(&pending))
        }
        XCTAssertTrue(decoder.isFinished)
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "Wikipedia in\r\n\r\nchunks.")

        var malformed = PushChunkedDecoder()
        var bad = Data("zz\r\nabc".utf8)
        XCTAssertThrowsError(try malformed.decode(&bad))
        var missingTerminator = PushChunkedDecoder()
        var noCRLF = Data("3\r\nabcXX".utf8)
        XCTAssertThrowsError(try missingTerminator.decode(&noCRLF))
    }

    func testRejectsMalformedAndOversizedRequests() throws {
        let processor = PushHTTPConnectionProcessor(router: StubRouter(route: .respond(.empty(200, "OK"))))
        XCTAssertTrue(try responseText(processor.receive(Data("NONSENSE\r\n\r\n".utf8))).hasPrefix("HTTP/1.1 400"))

        let huge = PushHTTPConnectionProcessor(router: StubRouter(route: .respond(.empty(200, "OK"))))
        let outputs = huge.receive(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8))
        XCTAssertTrue(try responseText(outputs).hasPrefix("HTTP/1.1 431"))

        let soap = PushHTTPConnectionProcessor(router: StubRouter(route: .collect(limit: 4) { _ in .empty(200, "OK") }))
        XCTAssertTrue(try responseText(soap.receive(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\n0123456789".utf8))).hasPrefix("HTTP/1.1 413"))
    }

    // MARK: Receiver exchange

    func testCameraExchangeDeliversACompleteVerifiedJPEG() throws {
        let events = ReceiverEvents()
        let receiver = makeReceiver(events)
        receiver.setBaseURL(URL(string: "http://192.168.54.10:49152")!)

        let description = try exchange(receiver, "GET /dms/ddd.xml HTTP/1.1\r\nHost: phone\r\n\r\n")
        XCTAssertTrue(description.contains("<friendlyName>Retro LUMIX Sync</friendlyName>"))
        let profiles = try exchange(receiver, soapRequest("X_GetDLNAUploadProfiles", "<GetUploadProfiles/>"))
        XCTAssertTrue(profiles.contains("<SupportedUploadProfiles>JPEG_LRG</SupportedUploadProfiles>"))

        let token = try createObject(receiver, title: "P1030516", size: Int64(jpeg.count))
        let upload = try exchange(receiver, chunkedUpload(token: token, body: jpeg, chunkSize: 700))
        XCTAssertTrue(upload.hasPrefix("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK"), upload)

        let file = try XCTUnwrap(events.completed.first)
        XCTAssertEqual(file.filename, "P1030516.JPG")
        XCTAssertEqual(file.byteCount, Int64(jpeg.count))
        XCTAssertEqual(try Data(contentsOf: file.fileURL), jpeg)
        XCTAssertEqual(file.sha256, SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(events.descriptionRequests, 1)
        XCTAssertEqual(events.profileRequests, 1)

        let reuse = try exchange(receiver, chunkedUpload(token: token, body: jpeg, chunkSize: 700))
        XCTAssertTrue(reuse.hasPrefix("HTTP/1.1 404"), "An import URI is single-use")
    }

    func testIncompleteUploadsAreDiscardedAndReported() throws {
        let events = ReceiverEvents()
        let receiver = makeReceiver(events)
        receiver.setBaseURL(URL(string: "http://192.168.54.10:49152")!)

        // The connection drops halfway through the body.
        let dropped = try createObject(receiver, title: "P1000010", size: nil)
        let processor = PushHTTPConnectionProcessor(router: receiver)
        let partial = Data("POST /upload/\(dropped) HTTP/1.1\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8) + jpeg.prefix(jpeg.count / 2)
        XCTAssertEqual(processor.receive(partial), [.send(PushHTTPResponse.continueInterim)])
        processor.connectionClosed()

        // The body is complete but the JPEG has no end marker.
        let truncated = try createObject(receiver, title: "P1000011", size: nil)
        let truncatedReply = try exchange(receiver, contentLengthUpload(token: truncated, body: jpeg.prefix(jpeg.count - 10)))
        XCTAssertTrue(truncatedReply.contains("HTTP/1.1 400"))

        // The camera announced a size and then sent less.
        let mismatched = try createObject(receiver, title: "P1000012", size: Int64(jpeg.count + 100))
        let mismatchReply = try exchange(receiver, contentLengthUpload(token: mismatched, body: jpeg))
        XCTAssertTrue(mismatchReply.contains("HTTP/1.1 400"))

        XCTAssertTrue(events.completed.isEmpty)
        XCTAssertEqual(events.failures.map(\.filename), ["P1000010.JPG", "P1000011.JPG", "P1000012.JPG"])
        guard case .connectionClosed = events.failures[0].failure else { return XCTFail("Expected a dropped connection") }
        guard case .incompleteJPEG = events.failures[1].failure else { return XCTFail("Expected an incomplete JPEG") }
        guard case .sizeMismatch = events.failures[2].failure else { return XCTFail("Expected a size mismatch") }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Partial files are deleted: \(leftovers)")
    }

    func testOversizedUploadIsRejectedAndUnknownActionsFault() throws {
        let events = ReceiverEvents()
        let receiver = PushTransferReceiver(
            configuration: .init(friendlyName: "Retro LUMIX Sync", deviceUUID: "UUID-1", uploadDirectory: directory,
                                 maximumUploadBytes: 100),
            emit: { events.record($0) }
        )
        receiver.setBaseURL(URL(string: "http://192.168.54.10:49152")!)
        let token = try createObject(receiver, title: "P1", size: nil)
        XCTAssertTrue(try exchange(receiver, chunkedUpload(token: token, body: jpeg, chunkSize: 4_000)).contains("HTTP/1.1 413"))

        let fault = try exchange(receiver, soapRequest("DestroyObject", "<ObjectID>1</ObjectID>"))
        XCTAssertTrue(fault.hasPrefix("HTTP/1.1 500"))
        XCTAssertTrue(fault.contains("<errorCode>401</errorCode>"))
        XCTAssertTrue(try exchange(receiver, "GET /secret HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 404"))
    }

    func testExpiredImportURIsAreRefused() throws {
        var now = Date()
        let events = ReceiverEvents()
        let receiver = PushTransferReceiver(
            configuration: .init(friendlyName: "Retro LUMIX Sync", deviceUUID: "UUID-1", uploadDirectory: directory, tokenLifetime: 60),
            now: { now },
            emit: { events.record($0) }
        )
        receiver.setBaseURL(URL(string: "http://192.168.54.10:49152")!)
        let token = try createObject(receiver, title: "P2", size: nil)
        now = now.addingTimeInterval(61)
        XCTAssertTrue(try exchange(receiver, chunkedUpload(token: token, body: jpeg, chunkSize: 500)).hasPrefix("HTTP/1.1 404"))
    }

    // MARK: Server

    func testServerAcceptsOnlyTheCameraAndAnswersOverTCP() async throws {
        #if os(macOS)
        throw XCTSkip("The sandboxed Mac test host cannot accept connections; receiving is iPhone-only.")
        #else
        let events = ReceiverEvents()
        let receiver = makeReceiver(events)
        let server = PushTransferHTTPServer(allowedPeerHost: "127.0.0.1", router: receiver)
        let port = try await server.start(preferredPorts: [])
        defer { server.stop() }
        receiver.setBaseURL(URL(string: "http://127.0.0.1:\(port)")!)

        let description = try await Self.roundTrip(port: port, request: Data("GET /dms/ddd.xml HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertTrue(description.contains("200 OK"))
        let token = try createObject(receiver, title: "P3", size: nil)
        let upload = try await Self.roundTrip(port: port, request: chunkedUpload(token: token, body: jpeg, chunkSize: 900))
        XCTAssertTrue(upload.contains("100 Continue") && upload.contains("200 OK"), upload)
        XCTAssertEqual(events.completed.count, 1)

        let foreignServer = PushTransferHTTPServer(allowedPeerHost: "192.168.54.1", router: receiver)
        let foreignPort = try await foreignServer.start(preferredPorts: [])
        defer { foreignServer.stop() }
        let refused = try? await Self.roundTrip(port: foreignPort, request: Data("GET /dms/ddd.xml HTTP/1.1\r\n\r\n".utf8))
        XCTAssertFalse(refused?.contains("200 OK") ?? false, "Connections from other hosts are refused")
        #endif
    }

    // MARK: Helpers

    private func makeReceiver(_ events: ReceiverEvents) -> PushTransferReceiver {
        PushTransferReceiver(
            configuration: .init(friendlyName: "Retro LUMIX Sync", deviceUUID: "UUID-1", uploadDirectory: directory),
            emit: { events.record($0) }
        )
    }

    private func createObject(_ receiver: PushTransferReceiver, title: String, size: Int64?) throws -> String {
        let sizeAttribute = size.map { " size=\"\($0)\"" } ?? ""
        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><item><dc:title>\(title)</dc:title>" +
            "<res\(sizeAttribute) protocolInfo=\"*:*:image/jpeg:*\"></res></item></DIDL-Lite>"
        let response = try exchange(receiver, soapRequest("CreateObject", "<ContainerID>0</ContainerID><Elements>\(didl.xmlEscapedForPush)</Elements>"))
        return try XCTUnwrap(response.firstCapture(of: "upload/([0-9a-f]+)"), response)
    }

    private func exchange(_ receiver: PushTransferReceiver, _ request: String) throws -> String {
        try exchange(receiver, Data(request.utf8))
    }

    private func exchange(_ receiver: PushTransferReceiver, _ request: Data) throws -> String {
        try responseText(PushHTTPConnectionProcessor(router: receiver).receive(request))
    }

    private func responseText(_ outputs: [PushHTTPOutput]) throws -> String {
        var data = Data()
        for case let .send(chunk) in outputs { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    private func soapRequest(_ action: String, _ body: String) -> String {
        let envelope = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:\(action) " +
            "xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">\(body)</u:\(action)></s:Body></s:Envelope>"
        return "POST /dms/control_0 HTTP/1.1\r\nHost: phone\r\nSOAPACTION: \"urn:schemas-upnp-org:service:ContentDirectory:1#\(action)\"\r\n" +
            "Content-Length: \(Data(envelope.utf8).count)\r\n\r\n" + envelope
    }

    private func chunkedUpload(token: String, body: Data, chunkSize: Int) -> Data {
        var request = Data("POST /upload/\(token) HTTP/1.1\r\nHost: phone\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n".utf8)
        var offset = 0
        while offset < body.count {
            let chunk = body[body.startIndex + offset..<body.startIndex + min(offset + chunkSize, body.count)]
            request.append(Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8))
            offset += chunkSize
        }
        request.append(Data("0\r\n\r\n".utf8))
        return request
    }

    private func contentLengthUpload(token: String, body: Data) -> Data {
        Data("POST /upload/\(token) HTTP/1.1\r\nHost: phone\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private static func roundTrip(port: UInt16, request: Data) async throws -> String {
        try await Task.detached {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            _ = request.withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count <= 0 { break }
                response.append(contentsOf: buffer[0..<count])
            }
            return String(decoding: response, as: UTF8.self)
        }.value
    }
}

private final class StubRouter: PushHTTPRouting {
    private let routeValue: PushHTTPRoute
    init(route: PushHTTPRoute) { routeValue = route }
    func route(_ head: PushHTTPRequestHead) -> PushHTTPRoute { routeValue }
}

private final class ReceiverEvents: @unchecked Sendable {
    struct Failure {
        let filename: String?
        let failure: PushUploadFailure
    }

    private let lock = NSLock()
    private var completedFiles: [PushReceivedFile] = []
    private var failureList: [Failure] = []
    private var descriptions = 0
    private var profiles = 0

    var completed: [PushReceivedFile] { lock.withLock { completedFiles } }
    var failures: [Failure] { lock.withLock { failureList } }
    var descriptionRequests: Int { lock.withLock { descriptions } }
    var profileRequests: Int { lock.withLock { profiles } }

    func record(_ event: PushTransferReceiverEvent) {
        lock.withLock {
            switch event {
            case let .uploadCompleted(file): completedFiles.append(file)
            case let .uploadFailed(_, filename, failure) where filename != nil: failureList.append(Failure(filename: filename, failure: failure))
            case .descriptionRequested: descriptions += 1
            case .uploadProfilesRequested: profiles += 1
            default: break
            }
        }
    }
}
