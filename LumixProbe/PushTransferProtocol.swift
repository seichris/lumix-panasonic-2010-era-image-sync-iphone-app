import Foundation

// "Send Images While Recording → Smartphone" makes the camera act as a DLNA
// uploader. It looks for a UPnP MediaServer that advertises image upload,
// reads its description, asks which upload profiles it accepts, calls
// ContentDirectory `CreateObject` for each new JPEG, and then POSTs the file
// (chunked) to the returned import URI.
//
// The message shapes follow KerbalNo15/Shutterlink, which its author tested on
// a GM1 and a G85. GM1S behavior still needs hardware confirmation.

enum PushTransferProtocol {
    static let ssdpMulticastAddress = "239.255.255.250"
    static let ssdpPort: UInt16 = 1900
    static let descriptionPath = "/dms/ddd.xml"
    static let serviceDescriptionPath = "/dms/sdd_0.xml"
    static let controlPath = "/dms/control_0"
    static let uploadPathPrefix = "/upload/"
    static let serverHeader = "iOS/17 UPnP/1.0 RetroLUMIXSync/1.0"
    static let mediaServerType = "urn:schemas-upnp-org:device:MediaServer:1"
    static let contentDirectoryType = "urn:schemas-upnp-org:service:ContentDirectory:1"
    static let connectionManagerType = "urn:schemas-upnp-org:service:ConnectionManager:1"
    /// The DLNA upload profile Shutterlink advertises. The camera's own image-size
    /// setting still decides how large the JPEG it sends is.
    static let uploadProfiles = "JPEG_LRG"
}

// MARK: - SSDP

struct SSDPMessage: Equatable, Sendable {
    /// `NOTIFY * HTTP/1.1`, `M-SEARCH * HTTP/1.1`, or `HTTP/1.1 200 OK` for responses.
    let startLine: String
    let headers: [String: String]

    var isSearchResponse: Bool { startLine.uppercased().hasPrefix("HTTP/1.1 200") }
    var isSearch: Bool { startLine.uppercased().hasPrefix("M-SEARCH") }

    func header(_ name: String) -> String? { headers[name.uppercased()] }

    static func parse(_ data: Data) -> SSDPMessage? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let startLine = lines.first?.trimmingCharacters(in: .whitespaces), !startLine.isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return SSDPMessage(startLine: startLine, headers: headers)
    }
}

/// Builds the SSDP datagrams that advertise the phone's upload receiver.
struct SSDPAdvertisement: Sendable {
    let deviceUUID: String
    let location: URL

    /// One NOTIFY per advertised type, as the UPnP device architecture requires.
    func notifications(alive: Bool) -> [Data] {
        let types: [(nt: String, usn: String)] = [
            ("uuid:\(deviceUUID)", "uuid:\(deviceUUID)"),
            ("upnp:rootdevice", "uuid:\(deviceUUID)::upnp:rootdevice"),
            (PushTransferProtocol.mediaServerType, "uuid:\(deviceUUID)::\(PushTransferProtocol.mediaServerType)"),
            (PushTransferProtocol.contentDirectoryType, "uuid:\(deviceUUID)::\(PushTransferProtocol.contentDirectoryType)"),
            (PushTransferProtocol.connectionManagerType, "uuid:\(deviceUUID)::\(PushTransferProtocol.connectionManagerType)")
        ]
        return types.map { type in
            var lines = [
                "NOTIFY * HTTP/1.1",
                "HOST: \(PushTransferProtocol.ssdpMulticastAddress):\(PushTransferProtocol.ssdpPort)"
            ]
            if alive {
                lines.append("CACHE-CONTROL: max-age=1800")
                lines.append("LOCATION: \(location.absoluteString)")
            }
            lines.append("NT: \(type.nt)")
            lines.append("NTS: \(alive ? "ssdp:alive" : "ssdp:byebye")")
            if alive { lines.append("SERVER: \(PushTransferProtocol.serverHeader)") }
            lines.append("USN: \(type.usn)")
            return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        }
    }

    /// A unicast reply to an M-SEARCH from the camera, or nil when the search is not for us.
    func searchResponse(for searchTarget: String) -> Data? {
        let usn: String
        let st: String
        switch searchTarget {
        case "ssdp:all", "upnp:rootdevice":
            usn = "uuid:\(deviceUUID)::upnp:rootdevice"
            st = "upnp:rootdevice"
        case "uuid:\(deviceUUID)":
            usn = searchTarget
            st = searchTarget
        case PushTransferProtocol.mediaServerType, PushTransferProtocol.contentDirectoryType,
             PushTransferProtocol.connectionManagerType:
            usn = "uuid:\(deviceUUID)::\(searchTarget)"
            st = searchTarget
        default:
            return nil
        }
        let response = [
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "EXT:",
            "LOCATION: \(location.absoluteString)",
            "SERVER: \(PushTransferProtocol.serverHeader)",
            "ST: \(st)",
            "USN: \(usn)"
        ]
        return Data((response.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A search the phone sends straight to the camera to confirm its SSDP service answers.
    static func cameraSearch(target: String = PushTransferProtocol.mediaServerType) -> Data {
        Data(([
            "M-SEARCH * HTTP/1.1",
            "HOST: \(PushTransferProtocol.ssdpMulticastAddress):\(PushTransferProtocol.ssdpPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 2",
            "ST: \(target)"
        ].joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A Panasonic-style device UUID (`4D454930-0100-1000-8001-` + 12 hex digits),
    /// stable per installation so the camera can recognize the destination again.
    static func persistentDeviceUUID(defaults: UserDefaults = .standard) -> String {
        let key = "pushTransferDeviceUUID.v1"
        if let stored = defaults.string(forKey: key), stored.count == 36 { return stored }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(12)
        let uuid = "4D454930-0100-1000-8001-" + suffix.uppercased()
        defaults.set(uuid, forKey: key)
        return uuid
    }
}

// MARK: - UPnP descriptions and SOAP

enum PushTransferDocuments {
    static func deviceDescription(friendlyName: String, deviceUUID: String) -> String {
        // The camera lists `friendlyName` as a destination. The manufacturer and model
        // identify a Panasonic-compatible upload server, as Shutterlink does.
        """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:vli="urn:schemas-panasonic-com:vli">
          <specVersion><major>1</major><minor>0</minor></specVersion>
          <device>
            <deviceType>\(PushTransferProtocol.mediaServerType)</deviceType>
            <friendlyName>\(friendlyName.xmlEscapedForPush)</friendlyName>
            <manufacturer>Panasonic</manufacturer>
            <modelName>LUMIX_UP_SERVER_SMP</modelName>
            <modelNumber>1.00</modelNumber>
            <UDN>uuid:\(deviceUUID)</UDN>
            <dlna:X_DLNADOC xmlns:dlna="urn:schemas-dlna-org:device-1-0">DMS-1.50</dlna:X_DLNADOC>
            <dlna:X_DLNACAP xmlns:dlna="urn:schemas-dlna-org:device-1-0">image-upload</dlna:X_DLNACAP>
            <serviceList>
              <service>
                <serviceType>\(PushTransferProtocol.contentDirectoryType)</serviceType>
                <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
                <SCPDURL>\(PushTransferProtocol.serviceDescriptionPath)</SCPDURL>
                <controlURL>\(PushTransferProtocol.controlPath)</controlURL>
                <eventSubURL>/dms/event_0</eventSubURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
    }

    static let serviceDescription = """
    <?xml version="1.0"?>
    <scpd xmlns="urn:schemas-upnp-org:service-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <actionList>
        <action><name>CreateObject</name><argumentList>
          <argument><name>ContainerID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument>
          <argument><name>Elements</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument>
          <argument><name>ObjectID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ObjectID</relatedStateVariable></argument>
          <argument><name>Result</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Result</relatedStateVariable></argument>
        </argumentList></action>
        <action><name>X_GetDLNAUploadProfiles</name><argumentList>
          <argument><name>GetUploadProfiles</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UploadProfiles</relatedStateVariable></argument>
          <argument><name>SupportedUploadProfiles</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UploadProfiles</relatedStateVariable></argument>
        </argumentList></action>
      </actionList>
      <serviceStateTable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_ObjectID</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_Result</name><dataType>string</dataType></stateVariable>
        <stateVariable sendEvents="no"><name>A_ARG_TYPE_UploadProfiles</name><dataType>string</dataType></stateVariable>
      </serviceStateTable>
    </scpd>
    """

    static func uploadProfilesResponse() -> String {
        soapEnvelope("""
        <u:X_GetDLNAUploadProfilesResponse xmlns:u="\(PushTransferProtocol.contentDirectoryType)">\
        <SupportedUploadProfiles>\(PushTransferProtocol.uploadProfiles)</SupportedUploadProfiles>\
        </u:X_GetDLNAUploadProfilesResponse>
        """)
    }

    static func createObjectResponse(objectID: String, title: String, importURI: URL) -> String {
        let didl = "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " +
            "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " +
            "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" +
            "<item id=\"\(objectID.xmlEscapedForPush)\" parentID=\"0\" restricted=\"0\">" +
            "<dc:title>\(title.xmlEscapedForPush)</dc:title>" +
            "<res importUri=\"\(importURI.absoluteString.xmlEscapedForPush)\" " +
            "protocolInfo=\"*:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_CI=0\"/>" +
            "<upnp:class>object.item.imageItem</upnp:class></item></DIDL-Lite>"
        return soapEnvelope("""
        <u:CreateObjectResponse xmlns:u="\(PushTransferProtocol.contentDirectoryType)">\
        <ObjectID>\(objectID.xmlEscapedForPush)</ObjectID>\
        <Result>\(didl.xmlEscapedForPush)</Result>\
        </u:CreateObjectResponse>
        """)
    }

    /// A UPnP SOAP fault (401 Invalid Action, 402 Invalid Args, 501 Action Failed).
    static func soapFault(code: Int, description: String) -> String {
        soapEnvelope("""
        <s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>\
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode>\
        <errorDescription>\(description.xmlEscapedForPush)</errorDescription></UPnPError></detail></s:Fault>
        """)
    }

    private static func soapEnvelope(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">\r\n" +
            "<s:Body>\(body)</s:Body>\r\n</s:Envelope>"
    }
}

/// What the camera announces about the image it is about to upload.
struct PushTransferUploadRequest: Equatable, Sendable {
    let title: String
    let declaredSize: Int64?
    let declaredResolution: String?
    let protocolInfo: String?

    init(title: String, declaredSize: Int64? = nil, declaredResolution: String? = nil, protocolInfo: String? = nil) {
        self.title = title
        self.declaredSize = declaredSize
        self.declaredResolution = declaredResolution
        self.protocolInfo = protocolInfo
    }

    /// The filename to record in Photos: the camera's title, made safe, with `.JPG`
    /// appended when it has no JPEG extension.
    var filename: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.filter { allowed.contains($0) && $0.isASCII }))
        let base = String(cleaned.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !base.isEmpty else { return "LUMIX.JPG" }
        let ext = (base as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg"].contains(ext) ? base : base + ".JPG"
    }

    /// Parses the `Elements` argument of a `CreateObject` SOAP request.
    static func parseCreateObject(_ soapBody: Data) -> PushTransferUploadRequest? {
        guard let envelope = LumixXML.parse(soapBody),
              let elements = envelope.firstDescendant(named: "Elements")?.trimmedText.nonEmptyValue else {
            return nil
        }
        // XMLParser has unescaped the SOAP text once; double-escaped bodies need one more pass.
        let didlText = elements.hasPrefix("&lt;") ? elements.pushHTMLUnescaped : elements
        guard let didl = LumixXML.parse(didlText),
              let item = didl.firstDescendant(named: "item") ?? didl.firstDescendant(named: "container"),
              let title = item.firstDescendant(named: "title")?.trimmedText.nonEmptyValue else {
            return nil
        }
        let resource = item.firstDescendant(named: "res")
        return PushTransferUploadRequest(
            title: title,
            declaredSize: resource?.attribute("size").flatMap { Int64($0) },
            declaredResolution: resource?.attribute("resolution"),
            protocolInfo: resource?.attribute("protocolInfo")
        )
    }
}

/// The SOAP action name from a `SOAPACTION` header such as
/// `"urn:schemas-upnp-org:service:ContentDirectory:1#CreateObject"`.
func pushTransferSOAPAction(_ header: String?) -> String? {
    guard let header else { return nil }
    let trimmed = header.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
    guard let hash = trimmed.lastIndex(of: "#") else { return trimmed.nonEmptyValue }
    return String(trimmed[trimmed.index(after: hash)...])
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
        .nonEmptyValue
}

extension String {
    var xmlEscapedForPush: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    var pushHTMLUnescaped: String {
        replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
