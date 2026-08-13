import Foundation

struct LumixHTTPResponse: Sendable {
    let url: URL
    let statusCode: Int
    let headers: [AnyHashable: Any]
    let data: Data

    var text: String { String(data: data, encoding: .utf8) ?? "<\(data.count) non-UTF8 bytes>" }
}

struct LumixContentInfo: Sendable {
    let currentPosition: Int?
    let totalContentNumber: Int?
    let contentNumber: Int?
}

struct LumixResource: Identifiable, Hashable, Sendable {
    let id = UUID()
    let itemID: String?
    let title: String?
    let url: URL
    let protocolInfo: String

    var profileName: String? {
        guard let range = protocolInfo.range(of: "PANASONIC.COM_PN=") else { return nil }
        let rest = protocolInfo[range.upperBound...]
        return String(rest.prefix { $0 != ";" })
    }

    var isOriginalJPEG: Bool { profileName == "CAM_ORG" }
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not construct Lumix URL."
        case .nonHTTPResponse: return "Camera returned a non-HTTP response."
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        case .missingBrowseResult: return "UPnP response did not contain a DIDL-Lite Result."
        case .noOriginalJPEG: return "No CAM_ORG JPEG was advertised in the browsed records."
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
    func requestAccess(clientName: String = "LumixProbe") async throws -> LumixHTTPResponse {
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
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"", forHTTPHeaderField: "SOAPACTION")
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

    func download(_ resource: LumixResource) async throws -> URL {
        var request = URLRequest(url: resource.url)
        request.timeoutInterval = 60
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw LumixError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else { throw LumixError.http(http.statusCode, "download failed") }

        let suggested = response.suggestedFilename ?? resource.url.lastPathComponent
        let filename = suggested.isEmpty ? "lumix-original.jpg" : suggested
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LumixError.nonHTTPResponse }
        let result = LumixHTTPResponse(url: request.url!, statusCode: http.statusCode, headers: http.allHeaderFields, data: data)
        guard (200..<300).contains(http.statusCode) else { throw LumixError.http(http.statusCode, result.text) }
        return result
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
    var htmlUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
