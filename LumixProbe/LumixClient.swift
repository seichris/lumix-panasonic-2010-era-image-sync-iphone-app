import Foundation
import Darwin

struct LumixHTTPResponse: Sendable {
    let url: URL
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    var text: String { String(data: data, encoding: .utf8) ?? "<\(data.count) non-UTF8 bytes>" }
}

struct LumixContentInfo: Sendable {
    let currentPosition: Int?
    let totalContentNumber: Int?
    let contentNumber: Int?
}

struct LumixResource: Identifiable, Hashable, Sendable {
    let itemID: String?
    let title: String?
    let url: URL
    let protocolInfo: String

    var id: String {
        [itemID ?? "", profileName ?? "", url.absoluteString].joined(separator: "|")
    }

    var profileName: String? {
        guard let range = protocolInfo.range(of: "PANASONIC.COM_PN=") else { return nil }
        let rest = protocolInfo[range.upperBound...]
        return String(rest.prefix { $0 != ";" })
    }

    var isOriginalJPEG: Bool {
        profileName == "CAM_ORG" || profileName == "CAM_RAW_JPG"
    }
}

struct LumixPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let itemID: String?
    let title: String
    let resources: [LumixResource]

    init(itemID: String?, title: String?, resources: [LumixResource]) {
        self.itemID = itemID
        self.title = title?.nonEmpty ?? resources.first?.url.deletingPathExtension().lastPathComponent.nonEmpty ?? "Camera photo"
        self.resources = resources
        id = itemID?.nonEmpty.map { "item:\($0)" }
            ?? title?.nonEmpty.map { "title:\($0)" }
            ?? "resource:\(resources.first?.url.absoluteString ?? "camera-photo")"
    }

    var thumbnailResource: LumixResource? {
        resource(preferredProfiles: ["CAM_TN", "CAM_LRGTN"])
    }

    var previewResource: LumixResource? {
        resource(preferredProfiles: ["CAM_LRGTN", "CAM_TN"])
    }

    var originalJPEGResource: LumixResource? {
        resource(preferredProfiles: ["CAM_ORG", "CAM_RAW_JPG"])
    }

    var rawResource: LumixResource? {
        resource(preferredProfiles: ["CAM_RAW"])
    }

    private func resource(preferredProfiles: [String]) -> LumixResource? {
        for profile in preferredProfiles {
            if let match = resources.first(where: { $0.profileName == profile }) { return match }
        }
        return nil
    }

    static func grouped(from resources: [LumixResource]) -> [LumixPhoto] {
        var order: [String] = []
        var grouped: [String: [LumixResource]] = [:]

        for resource in resources {
            let key = resource.itemID?.nonEmpty.map { "item:\($0)" }
                ?? resource.title?.nonEmpty.map { "title:\($0)" }
                ?? "resource:\(resource.url.deletingPathExtension().absoluteString)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(resource)
        }

        return order.compactMap { key in
            guard let itemResources = grouped[key], let first = itemResources.first else { return nil }
            return LumixPhoto(itemID: first.itemID, title: first.title, resources: itemResources)
        }
    }
}

struct LumixPhotoPage: Sendable {
    let startIndex: Int
    let numberReturned: Int
    let totalMatches: Int
    let photos: [LumixPhoto]
}

struct LumixBrowseResult: Sendable {
    let numberReturned: Int?
    let totalMatches: Int?
    let updateID: Int?
    let rawSOAP: String
    let didl: String
    let resources: [LumixResource]
}

enum LumixError: LocalizedError {
    case invalidURL
    case nonHTTPResponse
    case http(Int, String)
    case missingBrowseResult
    case noOriginalJPEG
    case missingContentCount

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not construct Lumix URL."
        case .nonHTTPResponse: return "Camera returned a non-HTTP response."
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        case .missingBrowseResult: return "UPnP response did not contain a DIDL-Lite Result."
        case .noOriginalJPEG: return "No original JPEG was advertised in the browsed records."
        case .missingContentCount: return "The camera did not report its media count after entering playback mode."
        }
    }
}

actor LumixClient {
    let host: String
    private let session: URLSession

    init(host: String = "192.168.54.1") {
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func getState() async throws -> LumixHTTPResponse {
        try await cameraGET(["mode": "getstate"])
    }

    /// Known request shape used by older Lumix remote-control clients.
    /// The GM1S response/approval behavior is intentionally left visible to the probe UI.
    func requestAccess(clientName: String = "GM1Sync") async throws -> LumixHTTPResponse {
        try await cameraGET([
            "mode": "accctrl",
            "type": "req_acc",
            "value": "0",
            "value2": clientName
        ])
    }

    func setRecordMode() async throws -> LumixHTTPResponse {
        try await cameraGET(["mode": "camcmd", "value": "recmode"])
    }

    func setPlayMode() async throws -> LumixHTTPResponse {
        try await cameraGET(["mode": "camcmd", "value": "playmode"])
    }

    func getContentInfo() async throws -> (LumixHTTPResponse, LumixContentInfo) {
        let response = try await cameraGET(["mode": "get_content_info"])
        let xml = SimpleXML(response.data)
        return (response, LumixContentInfo(
            currentPosition: xml.firstInt("current_position"),
            totalContentNumber: xml.firstInt("total_content_number"),
            contentNumber: xml.firstInt("content_number")
        ))
    }

    func browse(start: Int, count: Int) async throws -> LumixBrowseResult {
        guard let url = URL(string: "http://\(host):60606/Server0/CDS_control") else { throw LumixError.invalidURL }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1" xmlns:pana="urn:schemas-panasonic-com:pana">
              <ObjectID>0</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>\(max(0, start))</StartingIndex>
              <RequestedCount>\(max(1, count))</RequestedCount>
              <SortCriteria></SortCriteria>
              <pana:X_FromCP>LumixLink2.0</pana:X_FromCP>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("urn:schemas-upnp-org:service:ContentDirectory:1#Browse", forHTTPHeaderField: "SOAPAction")
        request.setValue("text/xml", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let response = try await send(request)
        let outer = SimpleXML(response.data)
        guard let escapedDIDL = outer.firstText("Result") else { throw LumixError.missingBrowseResult }
        let didl = escapedDIDL.htmlUnescaped
        let resources = DIDLParser.parse(didl)
        return LumixBrowseResult(
            numberReturned: outer.firstInt("NumberReturned"),
            totalMatches: outer.firstInt("TotalMatches"),
            updateID: outer.firstInt("UpdateID"),
            rawSOAP: response.text,
            didl: didl,
            resources: resources
        )
    }

    func browseLast(_ count: Int = 5) async throws -> LumixBrowseResult {
        let (_, info) = try await getContentInfo()
        let total = info.contentNumber ?? info.totalContentNumber ?? count
        return try await browse(start: max(0, total - count), count: min(count, max(total, 1)))
    }

    func prepareForBrowsing() async throws -> Int {
        _ = try await setPlayMode()

        for attempt in 0..<5 {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(350 * attempt))
            }
            let (_, info) = try await getContentInfo()
            if let total = info.contentNumber ?? info.totalContentNumber {
                return max(0, total)
            }
        }

        throw LumixError.missingContentCount
    }

    func browsePhotos(start: Int, count: Int) async throws -> LumixPhotoPage {
        let result = try await browse(start: start, count: count)
        let photos = LumixPhoto.grouped(from: result.resources)
        return LumixPhotoPage(
            startIndex: max(0, start),
            numberReturned: result.numberReturned ?? photos.count,
            totalMatches: result.totalMatches ?? max(start + photos.count, photos.count),
            photos: photos
        )
    }

    func downloadJPEGData(_ resource: LumixResource) async throws -> Data {
        let data = try await LegacyLumixMediaDownloader.downloadJPEG(from: resource.url)
        try Self.validateJPEG(data)
        return data
    }

    func download(_ resource: LumixResource) async throws -> URL {
        let data = try await downloadJPEGData(resource)

        let suggested = resource.url.lastPathComponent
        let filename = suggested.isEmpty ? "lumix-original.jpg" : suggested
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func validateJPEG(_ data: Data) throws {
        guard data.count >= 4,
              data[0] == 0xff,
              data[1] == 0xd8,
              data.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw LumixError.http(0, "download was not a complete JPEG (\(data.count) bytes)")
        }
    }

    private func cameraGET(_ query: [String: String]) async throws -> LumixHTTPResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/cam.cgi"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw LumixError.invalidURL }
        return try await send(URLRequest(url: url))
    }

    private func send(_ request: URLRequest) async throws -> LumixHTTPResponse {
        let maximumAttempts = 5

        for attempt in 0..<maximumAttempts {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LumixError.nonHTTPResponse }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, header in
                result[String(describing: header.key)] = String(describing: header.value)
            }
            let result = LumixHTTPResponse(
                url: request.url!,
                statusCode: http.statusCode,
                headers: headers,
                data: data
            )

            if http.statusCode == 503, attempt + 1 < maximumAttempts {
                try await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
                continue
            }

            guard (200..<300).contains(http.statusCode) else {
                throw LumixError.http(http.statusCode, result.text)
            }
            return result
        }

        preconditionFailure("The bounded request loop must return or throw.")
    }
}

/// The GM1 generation's port-50001 server predates modern URLSession behavior.
/// A deliberately small HTTP/1.0 client avoids persistent-connection negotiation
/// and matches the plain request accepted by the camera's legacy media server.
private enum LegacyLumixMediaDownloader {
    static func downloadJPEG(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try downloadJPEGBlocking(from: url)
        }.value
    }

    private static func downloadJPEGBlocking(from url: URL) throws -> Data {
        guard url.scheme == "http",
              let host = url.host,
              let port = url.port,
              port == 50001 else {
            throw LumixError.invalidURL
        }

        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXDownloadError("socket", errno) }
        defer { Darwin.close(fileDescriptor) }

        var noSignal = Int32(1)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))

        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fileDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw LumixError.invalidURL }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { throw POSIXDownloadError("connect", errno) }

        let path = url.path.isEmpty ? "/" : url.path
        let request = "GET \(path) HTTP/1.0\r\nHost: \(host):\(port)\r\nAccept: */*\r\nUser-Agent: GM1Sync/1.0\r\n\r\n"
        try sendAll(Data(request.utf8), to: fileDescriptor)

        var received = Data()
        var body = Data()
        var detector = JPEGCompletionDetector()
        var expectedLength: Int?
        var parsedHeaders = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXDownloadError("receive", errno)
            }

            let chunk = Data(buffer.prefix(count))
            if !parsedHeaders {
                received.append(chunk)
                guard let boundary = received.range(of: Data("\r\n\r\n".utf8)) else {
                    if received.count > 64 * 1024 { throw LumixError.http(0, "media response headers were too large") }
                    continue
                }

                let headerData = received[..<boundary.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                let statusCode = lines.first?
                    .split(separator: " ")
                    .dropFirst()
                    .first
                    .flatMap { Int($0) } ?? 0
                guard (200..<300).contains(statusCode) else {
                    throw LumixError.http(statusCode, headerText)
                }

                expectedLength = lines.dropFirst().first { line in
                    line.lowercased().hasPrefix("content-length:")
                }.flatMap { line in
                    Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
                }

                parsedHeaders = true
                let initialBody = received[boundary.upperBound...]
                if append(initialBody, to: &body, detector: &detector, expectedLength: expectedLength) { return body }
                received.removeAll(keepingCapacity: false)
            } else if append(chunk, to: &body, detector: &detector, expectedLength: expectedLength) {
                return body
            }

            if body.count > 100 * 1024 * 1024 {
                throw LumixError.http(0, "media response exceeded 100 MB")
            }
        }

        guard parsedHeaders,
              body.count >= 4,
              body[0] == 0xff,
              body[1] == 0xd8,
              body.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw LumixError.http(0, "camera closed an incomplete JPEG response (\(body.count) bytes)")
        }
        return body
    }

    private static func sendAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(fileDescriptor, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXDownloadError("send", errno)
                }
                sent += count
            }
        }
    }

    private static func append<C: Collection>(
        _ bytes: C,
        to body: inout Data,
        detector: inout JPEGCompletionDetector,
        expectedLength: Int?
    ) -> Bool where C.Element == UInt8 {
        for byte in bytes {
            body.append(byte)
            if let expectedLength, body.count >= expectedLength { return true }
            if detector.consume(byte) { return true }
        }
        return false
    }
}

private struct POSIXDownloadError: LocalizedError {
    let operation: String
    let code: Int32

    init(_ operation: String, _ code: Int32) {
        self.operation = operation
        self.code = code
    }

    var errorDescription: String? {
        "Legacy media \(operation) failed: \(String(cString: strerror(code))) (\(code))"
    }
}

/// Finds the end of the outer JPEG stream without mistaking a JPEG thumbnail
/// embedded inside an APP/EXIF segment for the end of the downloaded image.
struct JPEGCompletionDetector {
    private enum Phase {
        case seekingSOI
        case seekingMarker
        case markerCode
        case lengthHigh(UInt8)
        case lengthLow(marker: UInt8, high: UInt8)
        case segment(marker: UInt8, remaining: Int)
        case scan
        case scanAfterFF
        case complete
    }

    private var phase: Phase = .seekingSOI
    private var previousWasFF = false

    mutating func consume(_ byte: UInt8) -> Bool {
        switch phase {
        case .seekingSOI:
            if previousWasFF, byte == 0xd8 {
                phase = .seekingMarker
                previousWasFF = false
            } else {
                previousWasFF = byte == 0xff
            }

        case .seekingMarker:
            if byte == 0xff { phase = .markerCode }

        case .markerCode:
            if byte == 0xff { break }
            if byte == 0xd9 {
                phase = .complete
                return true
            }
            if byte == 0xd8 || byte == 0x01 || (0xd0...0xd7).contains(byte) {
                phase = .seekingMarker
            } else {
                phase = .lengthHigh(byte)
            }

        case let .lengthHigh(marker):
            phase = .lengthLow(marker: marker, high: byte)

        case let .lengthLow(marker, high):
            let length = (Int(high) << 8) | Int(byte)
            let payloadLength = max(0, length - 2)
            if payloadLength == 0 {
                phase = marker == 0xda ? .scan : .seekingMarker
            } else {
                phase = .segment(marker: marker, remaining: payloadLength)
            }

        case let .segment(marker, remaining):
            if remaining <= 1 {
                phase = marker == 0xda ? .scan : .seekingMarker
            } else {
                phase = .segment(marker: marker, remaining: remaining - 1)
            }

        case .scan:
            if byte == 0xff { phase = .scanAfterFF }

        case .scanAfterFF:
            if byte == 0x00 || (0xd0...0xd7).contains(byte) {
                phase = .scan
            } else if byte == 0xff {
                break
            } else if byte == 0xd9 {
                phase = .complete
                return true
            } else if byte == 0x01 || byte == 0xd8 {
                phase = .scan
            } else {
                phase = .lengthHigh(byte)
            }

        case .complete:
            return true
        }

        return false
    }
}

private final class SimpleXML: NSObject, XMLParserDelegate {
    private var current = ""
    private var buffer = ""
    private(set) var values: [String: [String]] = [:]

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        current = elementName
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { buffer += String(data: CDATABlock, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == current {
            values[elementName, default: []].append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        current = ""
        buffer = ""
    }

    func firstText(_ name: String) -> String? { values[name]?.first }
    func firstInt(_ name: String) -> Int? { firstText(name).flatMap(Int.init) }
}

private final class DIDLParser: NSObject, XMLParserDelegate {
    private var itemID: String?
    private var title: String?
    private var currentElement = ""
    private var currentText = ""
    private var currentProtocol = ""
    private var resources: [LumixResource] = []

    static func parse(_ xml: String) -> [LumixResource] {
        let parserDelegate = DIDLParser()
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return parserDelegate.resources
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "item" { itemID = attributeDict["id"]; title = nil }
        if elementName == "res" { currentProtocol = attributeDict["protocolInfo"] ?? "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName.hasSuffix("title") { title = value }
        if elementName == "res", let url = URL(string: value) {
            resources.append(LumixResource(itemID: itemID, title: title, url: url, protocolInfo: currentProtocol))
        }
        currentElement = ""
        currentText = ""
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    var htmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
