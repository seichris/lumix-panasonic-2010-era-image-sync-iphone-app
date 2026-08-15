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

struct CameraResourceKey: Hashable, Sendable {
    let mimeType: String
    let panasonicProfile: String?

    init(mimeType: String, panasonicProfile: String?) {
        self.mimeType = mimeType.lowercased()
        self.panasonicProfile = panasonicProfile?.uppercased()
    }
}

enum PanasonicPlayerKind: Hashable, Sendable {
    case dmpStream
    case standard
    case liveView
    case unknown(String)

    init(_ value: String?) {
        switch value?.lowercased() {
        case "hls": self = .dmpStream
        case "standard", "normal": self = .standard
        case "liveview", "live_view": self = .liveView
        case let value?: self = .unknown(value)
        case nil: self = .standard
        }
    }
}

struct PlaybackCapability: Hashable, Sendable {
    let enabled: Bool
    let player: PanasonicPlayerKind
    let functions: Set<String>
}

struct ContentActions: Hashable, Sendable {
    let playback: PlaybackCapability?
    let copyToPhone: Bool?
}

struct CameraContentAction: Hashable, Sendable {
    let type: String
    let enabled: Bool
    let operatingSystem: String?
    let player: String?
    let playerFunctions: Set<String>

    var appliesToIOS: Bool {
        guard let operatingSystem = operatingSystem?.lowercased().nonEmpty else { return true }
        return operatingSystem
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .contains("ios")
    }

    var isIOSSpecific: Bool { operatingSystem?.lowercased().contains("ios") == true }
}

struct CameraCapabilityEntry: Hashable, Sendable {
    let mimeType: String
    let panasonicProfiles: Set<String>
    let actions: [CameraContentAction]

    func matches(_ resource: LumixResource) -> Bool {
        guard resource.mimeType == mimeType.lowercased() else { return false }
        guard !panasonicProfiles.isEmpty else { return resource.profileName == nil }
        guard let profile = resource.profileName?.uppercased() else { return false }
        return panasonicProfiles.contains(profile)
    }

    func preferredAction(type: String) -> CameraContentAction? {
        let matching = actions.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame && $0.appliesToIOS }
        return matching.first(where: \.isIOSSpecific) ?? matching.first
    }
}

struct CameraCapabilities: Hashable, Sendable {
    let model: String?
    let version: String?
    let date: String?
    let entries: [CameraCapabilityEntry]

    func actions(for resource: LumixResource) -> ContentActions? {
        guard let entry = entries.first(where: { $0.matches(resource) }) else { return nil }
        let playbackAction = entry.preferredAction(type: "playback")
        let playback = playbackAction.map {
            PlaybackCapability(
                enabled: $0.enabled,
                player: PanasonicPlayerKind($0.player),
                functions: $0.playerFunctions
            )
        }
        let copyToPhone = entry.preferredAction(type: "copy_to_sp")?.enabled
        return ContentActions(playback: playback, copyToPhone: copyToPhone)
    }

    func copyAllowed(for resource: LumixResource) -> Bool? {
        actions(for: resource)?.copyToPhone
    }

    func playbackCapability(for resource: LumixResource) -> PlaybackCapability? {
        actions(for: resource)?.playback
    }
}

enum LumixResourceRole: String, Hashable, Sendable {
    case avchdPlayback360
    case primary720
    case highQuality1080
    case original
    case thumbnail
    case unknown
}

struct LumixResource: Identifiable, Hashable, Sendable {
    let itemID: String?
    let title: String?
    let url: URL
    let protocolInfo: String
    let upnpClass: String?
    let duration: TimeInterval?
    let resolutionWidth: Int?
    let resolutionHeight: Int?
    let size: Int64?
    let bitrate: Int?
    let chapterList: String?
    let captureDate: Date?

    init(
        itemID: String?,
        title: String?,
        url: URL,
        protocolInfo: String,
        upnpClass: String? = nil,
        duration: TimeInterval? = nil,
        resolutionWidth: Int? = nil,
        resolutionHeight: Int? = nil,
        size: Int64? = nil,
        bitrate: Int? = nil,
        chapterList: String? = nil,
        captureDate: Date? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.url = url
        self.protocolInfo = protocolInfo
        self.upnpClass = upnpClass
        self.duration = duration
        self.resolutionWidth = resolutionWidth
        self.resolutionHeight = resolutionHeight
        self.size = size
        self.bitrate = bitrate
        self.chapterList = chapterList
        self.captureDate = captureDate
    }

    var id: String {
        [itemID ?? "", profileName ?? "", url.absoluteString].joined(separator: "|")
    }

    var profileName: String? {
        guard let range = protocolInfo.range(of: "PANASONIC.COM_PN=") else { return nil }
        let rest = protocolInfo[range.upperBound...]
        return String(rest.prefix { $0 != ";" })
    }

    var isOriginalJPEG: Bool {
        guard !isLegacyAVCHDPlaceholder else { return false }
        if profileName == "CAM_ORG" || profileName == "CAM_RAW_JPG" { return true }
        return mimeType == "image/jpeg" && !isPreview
    }

    var isRAW: Bool {
        profileName == "CAM_RAW" || url.pathExtension.caseInsensitiveCompare("RW2") == .orderedSame
    }

    var isVideo: Bool {
        if isLegacyAVCHDPlaceholder { return true }
        if mimeType?.hasPrefix("video/") == true { return true }
        return ["mp4", "mov", "m4v", "mts", "m2ts"].contains(url.pathExtension.lowercased())
    }

    /// Keep the exact URI advertised by the camera. Panasonic's DLNA client
    /// passes AVCHD resource URIs through unchanged and changes the HTTP request
    /// semantics instead; rewriting the name to an SD-card-style `.MTS` path
    /// makes the GM1 media server return 404.
    var downloadURL: URL {
        url
    }

    var requiresDLNAStreamingRequest: Bool {
        if mimeType == "video/vnd.dlna.mpeg-tts" { return true }
        if mimeType == "video/mp2t" { return true }
        if profileName?.contains("CAM_AVC_TS_") == true { return true }
        if profileName?.contains("AVCHD") == true { return true }
        if ["mts", "m2ts"].contains(url.pathExtension.lowercased()) { return true }
        return isLegacyAVCHDPlaceholder
    }

    var isAVCHD: Bool { requiresDLNAStreamingRequest }

    var isPhoneCopyableVideoFormat: Bool {
        guard isVideo, !isAVCHD else { return false }
        return mimeType == "video/mp4"
            || ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    var role: LumixResourceRole {
        if isPreview { return .thumbnail }
        guard isAVCHD else { return isVideo ? .original : .unknown }
        let profile = profileName?.uppercased() ?? ""
        if profile.contains("_360_") { return .avchdPlayback360 }
        if profile.contains("_720_") { return .primary720 }
        if profile.contains("_1080_") { return .highQuality1080 }
        return .original
    }

    var dlnaOperations: String? { protocolParameter("DLNA.ORG_OP") }
    var dlnaFlags: String? { protocolParameter("DLNA.ORG_FLAGS") }

    var isPreview: Bool {
        profileName == "CAM_TN" || profileName == "CAM_LRGTN"
    }

    var mimeType: String? {
        let components = protocolInfo.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        return components[2].split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
    }

    private var isLegacyAVCHDPlaceholder: Bool {
        legacyAVCHDNameComponents != nil
    }

    private func protocolParameter(_ name: String) -> String? {
        protocolInfo
            .split(separator: ";")
            .dropFirst()
            .compactMap { component -> (String, String)? in
                let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { return nil }
                return (pair[0], pair[1])
            }
            .first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?
            .1
    }

    private var legacyAVCHDNameComponents: (base: String, suffix: String)? {
        guard ["jpg", "jpeg", "mts", "ts"].contains(url.pathExtension.lowercased()) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.uppercased().hasPrefix("DO") else { return nil }
        let digits = String(stem.dropFirst(2))
        guard digits.allSatisfy(\.isNumber) else { return nil }

        switch digits.count {
        case 12:
            return (String(digits.prefix(8)), String(digits.suffix(4)))
        case 20:
            let folder = digits.prefix(10)
            guard folder.hasPrefix("00") else { return nil }
            return (String(folder.dropFirst(2)), String(digits.suffix(4)))
        default:
            return nil
        }
    }
}

enum LumixMediaKind: String, Hashable, Sendable {
    case photo
    case video
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
        resource(preferredProfiles: ["CAM_RAW"]) ?? resources.first(where: \.isRAW)
    }

    var videoResource: LumixResource? {
        resources
            .filter { $0.isVideo && !$0.isPreview }
            .sorted { Self.videoPriority($0) < Self.videoPriority($1) }
            .first
    }

    /// Panasonic's phone player prefers the 360p AVCHD resource while keeping
    /// the highest-quality resource for copy/export. On a GM1, requesting the
    /// original transport-stream resource as a plain file returns 404.
    var videoPlaybackResource: LumixResource? {
        resources
            .filter { $0.isVideo && !$0.isPreview }
            .sorted { Self.videoPlaybackPriority($0) < Self.videoPlaybackPriority($1) }
            .first
    }

    var kind: LumixMediaKind {
        videoResource == nil ? .photo : .video
    }

    /// Best-effort timestamp advertised by the camera's content directory.
    /// Import still verifies the original JPEG's EXIF capture time.
    var captureDate: Date? {
        resources.compactMap(\.captureDate).first
    }

    var isImportable: Bool {
        switch kind {
        case .photo: originalJPEGResource != nil || rawResource != nil
        case .video: videoResource?.isPhoneCopyableVideoFormat == true
        }
    }

    var importIdentity: String {
        let originals = resources
            .filter { $0.isOriginalJPEG || $0.isRAW || $0.isVideo }
            .map(\.downloadURL.lastPathComponent)
            .sorted()
        return ([itemID ?? "", title] + originals).joined(separator: "|")
    }

    var displayFilename: String {
        switch kind {
        case .video:
            return videoResource?.downloadURL.lastPathComponent.nonEmpty ?? title
        case .photo:
            return originalJPEGResource?.downloadURL.lastPathComponent.nonEmpty
                ?? rawResource?.downloadURL.lastPathComponent.nonEmpty
                ?? title
        }
    }

    private func resource(preferredProfiles: [String]) -> LumixResource? {
        for profile in preferredProfiles {
            if let match = resources.first(where: { $0.profileName == profile }) { return match }
        }
        return nil
    }

    private static func videoPriority(_ resource: LumixResource) -> Int {
        switch resource.downloadURL.pathExtension.lowercased() {
        case "mp4": 0
        case "mov", "m4v": 1
        case "mts", "m2ts": 2
        default: 3
        }
    }

    private static func videoPlaybackPriority(_ resource: LumixResource) -> Int {
        guard resource.requiresDLNAStreamingRequest else {
            return videoPriority(resource)
        }
        switch resource.role {
        case .avchdPlayback360: return 10
        case .primary720: return 11
        case .highQuality1080: return 12
        default: return 13
        }
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

enum LumixBrowseFlag: String, Sendable {
    case directChildren = "BrowseDirectChildren"
    case metadata = "BrowseMetadata"
}

enum LumixBrowseSOAP {
    static func make(
        objectID: String,
        flag: LumixBrowseFlag,
        start: Int,
        count: Int
    ) -> String {
        let panasonicExtension = flag == .directChildren
            ? "<pana:X_FromCP>LumixLink2.0</pana:X_FromCP>"
            : ""
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1" xmlns:pana="urn:schemas-panasonic-com:pana">
              <ObjectID>\(objectID.xmlEscaped)</ObjectID>
              <BrowseFlag>\(flag.rawValue)</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>\(max(0, start))</StartingIndex>
              <RequestedCount>\(max(1, count))</RequestedCount>
              <SortCriteria></SortCriteria>
              \(panasonicExtension)
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
    }
}

enum LumixError: LocalizedError, Equatable {
    case invalidURL
    case nonHTTPResponse
    case http(Int, String)
    case missingBrowseResult
    case noOriginalJPEG
    case noRAW
    case noVideo
    case videoImportNotSupported
    case videoPlaybackNotSupported
    case missingContentCount

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not construct Lumix URL."
        case .nonHTTPResponse: return "Camera returned a non-HTTP response."
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        case .missingBrowseResult: return "UPnP response did not contain a DIDL-Lite Result."
        case .noOriginalJPEG: return "This camera item does not advertise an original JPEG."
        case .noRAW: return "This camera item does not advertise a RAW companion."
        case .noVideo: return "This camera item does not advertise a downloadable video."
        case .videoImportNotSupported:
            return "This camera does not permit this video format to be copied to iPhone."
        case .videoPlaybackNotSupported:
            return "This camera does not permit this video format to be played on the phone."
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

    func getState(timeoutInterval: TimeInterval? = nil) async throws -> LumixHTTPResponse {
        try await cameraGET(["mode": "getstate"], timeoutInterval: timeoutInterval)
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

    func fetchCapabilities() async throws -> CameraCapabilities {
        let response = try await cameraGET(["mode": "getinfo", "type": "capability"])
        return CameraCapabilityParser.parse(response.data)
    }

    func browse(start: Int, count: Int) async throws -> LumixBrowseResult {
        try await performBrowse(
            objectID: "0",
            flag: .directChildren,
            start: start,
            count: count
        )
    }

    func browseMetadata(itemID: String) async throws -> LumixPhoto {
        let result = try await performBrowse(
            objectID: itemID,
            flag: .metadata,
            start: 0,
            count: 1
        )
        let photos = LumixPhoto.grouped(from: result.resources)
        guard let photo = photos.first(where: { $0.itemID == itemID }) ?? photos.first else {
            throw LumixError.missingBrowseResult
        }
        return photo
    }

    func makeAVCHDPlaybackSession(
        for resource: LumixResource,
        availableResources: [LumixResource]
    ) async throws -> any CameraPlaybackSession {
        guard resource.isAVCHD else { throw LumixError.videoPlaybackNotSupported }
        return PanasonicAVCHDPlaybackSession(
            resource: resource,
            availableResources: availableResources
        )
    }

    private func performBrowse(
        objectID: String,
        flag: LumixBrowseFlag,
        start: Int,
        count: Int
    ) async throws -> LumixBrowseResult {
        guard let url = URL(string: "http://\(host):60606/Server0/CDS_control") else { throw LumixError.invalidURL }
        let body = LumixBrowseSOAP.make(objectID: objectID, flag: flag, start: start, count: count)

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
        try await LegacyLumixMediaDownloader.downloadFile(
            from: resource.downloadURL,
            validatesJPEG: resource.isOriginalJPEG && !resource.isVideo,
            requestStyle: resource.requiresDLNAStreamingRequest ? .panasonicDLNAInitial : .legacy
        )
    }

    func downloadMetadataPrefix(_ resource: LumixResource) async throws -> URL {
        try await LegacyLumixMediaDownloader.downloadFile(
            from: resource.downloadURL,
            requestStyle: .legacy,
            maximumBodyBytes: 512 * 1024,
            socketTimeoutSeconds: 12
        )
    }

    private static func validateJPEG(_ data: Data) throws {
        guard data.count >= 4,
              data[0] == 0xff,
              data[1] == 0xd8,
              data.suffix(2).elementsEqual([0xff, 0xd9]) else {
            throw LumixError.http(0, "download was not a complete JPEG (\(data.count) bytes)")
        }
    }

    private func cameraGET(
        _ query: [String: String],
        timeoutInterval: TimeInterval? = nil
    ) async throws -> LumixHTTPResponse {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = "/cam.cgi"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw LumixError.invalidURL }
        var request = URLRequest(url: url)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        return try await send(request)
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

enum LumixMediaRequestStyle: Sendable {
    case legacy
    case panasonicDLNAInitial
}

enum PanasonicDLNARemoteRange {
    /// Panasonic's native transport owns the camera-side seek state. A local
    /// player probe beginning at byte zero is still the native initial mode and
    /// must not become a camera `Range` request. Only a positive byte seek uses
    /// the native range request template.
    static func fromLocalPlayerRange(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            return nil
        }
        let components = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard components.count == 2,
              components[0].caseInsensitiveCompare("bytes") == .orderedSame,
              let firstRange = components[1].split(separator: ",", maxSplits: 1).first,
              let startText = firstRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first,
              let start = Int64(startText),
              start > 0 else {
            return nil
        }
        return value
    }
}

enum LumixMediaHTTPRequest {
    static func make(
        for url: URL,
        style: LumixMediaRequestStyle,
        rangeHeader: String? = nil
    ) throws -> String {
        guard let host = url.host else { throw LumixError.invalidURL }

        // Panasonic's native transport copies the request target from the
        // advertised URI byte-for-byte. URL.path decodes percent escapes, which
        // can silently turn a valid DLNA URI into a different camera path.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let encodedPath = components?.percentEncodedPath.nonEmpty ?? url.path
        var requestTarget = encodedPath.isEmpty ? "/" : encodedPath
        if let query = components?.percentEncodedQuery?.nonEmpty {
            requestTarget += "?\(query)"
        }

        switch style {
        case .legacy:
            let port = url.port.map { ":\($0)" } ?? ""
            return "GET \(requestTarget) HTTP/1.0\r\nHost: \(host)\(port)\r\nAccept: */*\r\nUser-Agent: GM1Sync/1.0\r\n\r\n"
        case .panasonicDLNAInitial:
            // Panasonic's native DLNA transport starts with this exact plain
            // request. Range and TimeSeekRange are only added after a seek.
            let range = rangeHeader?.nonEmpty.map { "Range: \($0)\r\n" } ?? ""
            return "GET \(requestTarget) HTTP/1.1\r\n" +
                "User-Agent: Panasonic Android/1 DM-CP\r\n" +
                "Host: \(host)\r\n" +
                range +
                "\r\n"
        }
    }
}

/// The GM1 generation's port-50001 server predates modern URLSession behavior.
/// A deliberately small socket client can issue both the plain HTTP/1.0 request
/// used for photos and Panasonic's exact initial HTTP/1.1 DLNA request.
private enum LegacyLumixMediaDownloader {
    static func downloadJPEG(from url: URL) async throws -> Data {
        let fileURL = try await downloadFile(from: url, validatesJPEG: true, requestStyle: .legacy)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try Data(contentsOf: fileURL)
    }

    static func downloadFile(
        from url: URL,
        validatesJPEG: Bool = false,
        requestStyle: LumixMediaRequestStyle = .legacy,
        maximumBodyBytes: Int? = nil,
        socketTimeoutSeconds: Int = 90
    ) async throws -> URL {
        let suggestedName = url.lastPathComponent.isEmpty ? "lumix-media" : url.lastPathComponent
        let traceID = "\(String(UUID().uuidString.prefix(8))) \(suggestedName)"
        let operation = LegacyLumixDownloadOperation()
        let continuationGate = LegacyLumixDownloadContinuationGate()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + suggestedName)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard continuationGate.install(continuation) else {
                    logLegacyMedia(traceID, "continuation already terminal; worker not scheduled.")
                    return
                }
                // recv(2) is intentionally blocking for compatibility with the
                // camera's HTTP/1.0 server. Keep it off Swift's cooperative task
                // pool so thumbnails cannot starve timers and cancellation.
                DispatchQueue.global(qos: .userInitiated).async {
                    logLegacyMedia(traceID, "GCD worker start for \(suggestedName).")
                    do {
                        let retryDelaysMicroseconds: [useconds_t] = maximumBodyBytes == nil
                            ? [0, 300_000, 800_000]
                            : [0]
                        var lastError: Error?

                        for (attempt, delay) in retryDelaysMicroseconds.enumerated() {
                            try operation.checkCancellation()
                            if delay > 0 {
                                usleep(delay)
                                try operation.checkCancellation()
                            }

                            do {
                                let fileURL = try downloadBlocking(
                                    from: url,
                                    to: destination,
                                    validatesJPEG: validatesJPEG,
                                    requestStyle: requestStyle,
                                    maximumBodyBytes: maximumBodyBytes,
                                    socketTimeoutSeconds: socketTimeoutSeconds,
                                    operation: operation,
                                    traceID: traceID
                                )
                                let result: Result<URL, Error> = .success(fileURL)
                                let won = continuationGate.resume(result)
                                logLegacyMedia(traceID, "continuation resume source=worker success won=\(won).")
                                if !won { try? FileManager.default.removeItem(at: fileURL) }
                                return
                            } catch {
                                lastError = error
                                let hasAnotherAttempt = attempt + 1 < retryDelaysMicroseconds.count
                                guard hasAnotherAttempt, LumixMediaDownloadRetryPolicy.shouldRetry(error) else {
                                    throw error
                                }
                                print(
                                    "[GM1Sync] Camera media transfer ended early for \(suggestedName); " +
                                        "retrying attempt \(attempt + 2) of \(retryDelaysMicroseconds.count)."
                                )
                            }
                        }

                        throw lastError ?? LumixError.http(0, "camera media download failed")
                    } catch {
                        let result: Result<URL, Error> = .failure(error)
                        let won = continuationGate.resume(result)
                        logLegacyMedia(
                            traceID,
                            "continuation resume source=worker failure won=\(won) error=\(error.localizedDescription)."
                        )
                    }
                }
            }
        } onCancel: {
            let won = continuationGate.resume(.failure(CancellationError()))
            logLegacyMedia(traceID, "continuation resume source=task cancellation won=\(won).")
            operation.cancel()
        }
    }

    private static func downloadBlocking(
        from url: URL,
        to destination: URL,
        validatesJPEG: Bool,
        requestStyle: LumixMediaRequestStyle,
        maximumBodyBytes: Int?,
        socketTimeoutSeconds: Int,
        operation: LegacyLumixDownloadOperation,
        traceID: String
    ) throws -> URL {
        guard url.scheme == "http",
              let host = url.host,
              let port = url.port,
              port == 50001 else {
            throw LumixError.invalidURL
        }

        logLegacyMedia(traceID, "socket creation enter.")
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            let socketError = errno
            logLegacyMedia(traceID, "socket creation failed errno=\(socketError).")
            throw POSIXDownloadError("socket", socketError)
        }
        logLegacyMedia(traceID, "socket creation exit fd=\(fileDescriptor).")
        defer { Darwin.close(fileDescriptor) }
        try operation.register(fileDescriptor)
        logLegacyMedia(traceID, "descriptor registered fd=\(fileDescriptor).")
        defer { operation.unregister(fileDescriptor) }
        try operation.checkCancellation()

        var noSignal = Int32(1)
        try setLegacySocketOption(
            fileDescriptor,
            name: SO_NOSIGPIPE,
            value: &noSignal,
            label: "SO_NOSIGPIPE",
            traceID: traceID
        )

        var timeout = timeval(tv_sec: max(1, socketTimeoutSeconds), tv_usec: 0)
        try setLegacySocketOption(
            fileDescriptor,
            name: SO_RCVTIMEO,
            value: &timeout,
            label: "SO_RCVTIMEO",
            traceID: traceID
        )
        try setLegacySocketOption(
            fileDescriptor,
            name: SO_SNDTIMEO,
            value: &timeout,
            label: "SO_SNDTIMEO",
            traceID: traceID
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw LumixError.invalidURL }

        try connectLegacySocket(
            fileDescriptor,
            address: &address,
            timeoutSeconds: socketTimeoutSeconds,
            operation: operation,
            traceID: traceID
        )

        let request = try LumixMediaHTTPRequest.make(for: url, style: requestStyle)
        try sendAll(
            Data(request.utf8),
            to: fileDescriptor,
            operation: operation,
            traceID: traceID
        )

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw POSIXDownloadError("create file", EIO)
        }
        let file = try FileHandle(forWritingTo: destination)
        var keepFile = false
        defer {
            try? file.close()
            if !keepFile { try? FileManager.default.removeItem(at: destination) }
        }

        var received = Data()
        var detector = JPEGCompletionDetector()
        var jpegComplete = false
        var bodyCount = 0
        var expectedLength: Int?
        var parsedHeaders = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var receiveCount = 0

        func appendBody(_ chunk: Data) throws -> Bool {
            var data: Data
            if let expectedLength {
                let remaining = max(0, expectedLength - bodyCount)
                data = Data(chunk.prefix(remaining))
            } else {
                data = chunk
            }

            if let maximumBodyBytes {
                let remaining = max(0, maximumBodyBytes - bodyCount)
                data = Data(data.prefix(remaining))
            }

            guard !data.isEmpty else {
                return expectedLength.map { bodyCount >= $0 } ?? false
            }

            if validatesJPEG {
                var completeByteCount = 0
                for byte in data {
                    completeByteCount += 1
                    if detector.consume(byte) {
                        jpegComplete = true
                        data = Data(data.prefix(completeByteCount))
                        break
                    }
                }
            }
            if bodyCount == 0 {
                let bodyPrefix = data.prefix(16)
                    .map { String(format: "%02x", $0) }
                    .joined(separator: " ")
                logLegacyMedia(
                    traceID,
                    "first body bytes count=\(data.count) hex=\(bodyPrefix)."
                )
            }
            try file.write(contentsOf: data)
            bodyCount += data.count

            if let maximumBodyBytes, bodyCount >= maximumBodyBytes { return true }
            if let expectedLength, bodyCount >= expectedLength { return true }
            return validatesJPEG && jpegComplete
        }

        receiveLoop: while true {
            try operation.checkCancellation()
            receiveCount += 1
            if maximumBodyBytes != nil || receiveCount == 1 {
                logLegacyMedia(traceID, "recv #\(receiveCount) enter; bodyBytes=\(bodyCount).")
            }
            let count = Darwin.recv(fileDescriptor, &buffer, buffer.count, 0)
            if count == 0 {
                logLegacyMedia(traceID, "recv #\(receiveCount) returned EOF; bodyBytes=\(bodyCount).")
                try operation.checkCancellation()
                break
            }
            if count < 0 {
                let receiveError = errno
                logLegacyMedia(traceID, "recv #\(receiveCount) failed errno=\(receiveError).")
                if receiveError == EINTR { continue }
                try operation.checkCancellation()
                throw POSIXDownloadError("receive", receiveError)
            }
            if maximumBodyBytes != nil || receiveCount == 1 {
                logLegacyMedia(traceID, "recv #\(receiveCount) exit bytes=\(count).")
            }

            let chunk = Data(buffer.prefix(count))
            if receiveCount == 1 {
                let responsePrefix = String(decoding: chunk.prefix(80), as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\n", with: "\\n")
                logLegacyMedia(
                    traceID,
                    "first response bytes count=\(chunk.count) prefix=\(responsePrefix)."
                )
            }
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
                    let lowercased = line.lowercased()
                    return lowercased.hasPrefix("content-length:")
                        || lowercased.hasPrefix("x-file_size:")
                }.flatMap { line in
                    Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
                }

                parsedHeaders = true
                logLegacyMedia(
                    traceID,
                    "headers parsed status=\(statusCode) expectedLength=\(expectedLength.map(String.init) ?? "unknown")."
                )
                let initialBody = Data(received[boundary.upperBound...])
                if try appendBody(initialBody) { break receiveLoop }
                received.removeAll(keepingCapacity: false)
            } else if try appendBody(chunk) {
                break receiveLoop
            }
        }

        logLegacyMedia(
            traceID,
            "receive complete bodyBytes=\(bodyCount) limit=\(maximumBodyBytes.map(String.init) ?? "none")."
        )
        if maximumBodyBytes != nil {
            guard parsedHeaders, bodyCount > 0 else {
                throw LumixError.http(0, "camera returned an empty JPEG metadata prefix")
            }
        } else {
            try LumixMediaDownloadCompletion.validate(
                parsedHeaders: parsedHeaders,
                bodyCount: bodyCount,
                expectedLength: expectedLength,
                validatesJPEG: validatesJPEG,
                jpegComplete: jpegComplete
            )
        }

        try operation.checkCancellation()
        keepFile = true
        return destination
    }

    private static func sendAll(
        _ data: Data,
        to fileDescriptor: Int32,
        operation: LegacyLumixDownloadOperation,
        traceID: String
    ) throws {
        logLegacyMedia(traceID, "send request enter bytes=\(data.count).")
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < rawBuffer.count {
                try operation.checkCancellation()
                let count = Darwin.send(fileDescriptor, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if count < 0 {
                    let sendError = errno
                    if sendError == EINTR { continue }
                    try operation.checkCancellation()
                    throw POSIXDownloadError("send", sendError)
                }
                guard count > 0 else { throw POSIXDownloadError("send", EPIPE) }
                sent += count
            }
        }
        logLegacyMedia(traceID, "send request exit.")
    }

    private static func setLegacySocketOption<Value>(
        _ fileDescriptor: Int32,
        name: Int32,
        value: inout Value,
        label: String,
        traceID: String
    ) throws {
        let result = withUnsafeBytes(of: &value) { bytes in
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                name,
                bytes.baseAddress,
                socklen_t(bytes.count)
            )
        }
        let optionError = result == 0 ? 0 : errno
        logLegacyMedia(traceID, "\(label) result=\(result) errno=\(optionError).")
        guard result == 0 else {
            throw POSIXDownloadError("setsockopt \(label)", optionError)
        }
    }

    private static func connectLegacySocket(
        _ fileDescriptor: Int32,
        address: inout sockaddr_in,
        timeoutSeconds: Int,
        operation: LegacyLumixDownloadOperation,
        traceID: String
    ) throws {
        let originalFlags = fcntl(fileDescriptor, F_GETFL, 0)
        let getFlagsError = originalFlags >= 0 ? 0 : errno
        logLegacyMedia(traceID, "fcntl F_GETFL result=\(originalFlags) errno=\(getFlagsError).")
        guard originalFlags >= 0 else {
            throw POSIXDownloadError("fcntl F_GETFL", getFlagsError)
        }
        let nonblockingResult = fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK)
        let nonblockingError = nonblockingResult == 0 ? 0 : errno
        logLegacyMedia(
            traceID,
            "fcntl F_SETFL O_NONBLOCK result=\(nonblockingResult) errno=\(nonblockingError)."
        )
        guard nonblockingResult == 0 else {
            throw POSIXDownloadError("fcntl F_SETFL O_NONBLOCK", nonblockingError)
        }

        func restoreBlockingMode() throws {
            let restoreResult = fcntl(fileDescriptor, F_SETFL, originalFlags)
            let restoreError = restoreResult == 0 ? 0 : errno
            logLegacyMedia(
                traceID,
                "fcntl restore blocking result=\(restoreResult) errno=\(restoreError)."
            )
            guard restoreResult == 0 else {
                throw POSIXDownloadError("fcntl restore blocking", restoreError)
            }
        }

        try operation.checkCancellation()
        logLegacyMedia(traceID, "connect enter with \(max(1, timeoutSeconds))-second deadline.")
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            try restoreBlockingMode()
            logLegacyMedia(traceID, "connect complete immediately.")
            return
        }

        let connectError = errno
        guard connectError == EINPROGRESS else {
            try operation.checkCancellation()
            logLegacyMedia(traceID, "connect failed immediately errno=\(connectError).")
            throw POSIXDownloadError("connect", connectError)
        }

        let timeoutNanoseconds = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt > UInt64.max - timeoutNanoseconds
            ? UInt64.max
            : startedAt + timeoutNanoseconds
        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        var pollCount = 0

        while true {
            try operation.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                logLegacyMedia(traceID, "connect deadline expired after \(pollCount) polls.")
                throw POSIXDownloadError("connect", ETIMEDOUT)
            }

            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = remainingNanoseconds / 1_000_000
                + (remainingNanoseconds % 1_000_000 == 0 ? 0 : 1)
            let remainingMilliseconds = Int32(
                min(UInt64(250), max(UInt64(1), roundedMilliseconds))
            )
            descriptor.revents = 0
            pollCount += 1
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult == 0 {
                logLegacyMedia(traceID, "connect poll #\(pollCount) pending.")
                continue
            }
            if pollResult < 0 {
                let pollError = errno
                if pollError == EINTR { continue }
                logLegacyMedia(traceID, "connect poll failed errno=\(pollError).")
                throw POSIXDownloadError("connect poll", pollError)
            }

            var socketError: Int32 = 0
            var socketErrorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
            let socketErrorResult = getsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_ERROR,
                &socketError,
                &socketErrorLength
            )
            if socketErrorResult != 0 {
                let optionError = errno
                logLegacyMedia(traceID, "connect SO_ERROR lookup failed errno=\(optionError).")
                throw POSIXDownloadError("getsockopt SO_ERROR", optionError)
            }
            guard socketError == 0 else {
                logLegacyMedia(traceID, "connect completed with errno=\(socketError).")
                throw POSIXDownloadError("connect", socketError)
            }

            try operation.checkCancellation()
            try restoreBlockingMode()
            logLegacyMedia(traceID, "connect complete after \(pollCount) polls.")
            return
        }
    }

}

private func logLegacyMedia(_ traceID: String, _ message: String) {
    print("[GM1Sync] [LegacyMedia \(traceID)] \(message)")
}

private let legacyLumixCancellationQueue = DispatchQueue(
    label: "com.web3.gm1sync.legacy-media-cancellation",
    qos: .userInitiated,
    attributes: .concurrent
)

private final class LegacyLumixDownloadContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?
    private var isFinished = false

    @discardableResult
    func install(_ continuation: CheckedContinuation<URL, Error>) -> Bool {
        lock.lock()
        if isFinished {
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            if let result { continuation.resume(with: result) }
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func resume(_ result: Result<URL, Error>) -> Bool {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return false
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

enum LumixMediaDownloadCompletion {
    static func validate(
        parsedHeaders: Bool,
        bodyCount: Int,
        expectedLength: Int?,
        validatesJPEG: Bool,
        jpegComplete: Bool
    ) throws {
        guard parsedHeaders, bodyCount > 0 else {
            throw LumixError.http(0, "camera returned an empty media response")
        }

        if validatesJPEG {
            // Some Image App-era cameras advertise a larger X-File_Size than
            // the JPEG payload they actually send. A structurally complete JPEG
            // ending at its real EOI marker is safe to import even when that
            // legacy size header does not match the payload byte count.
            guard jpegComplete else {
                throw LumixError.http(0, "camera closed an incomplete JPEG response (\(bodyCount) bytes)")
            }
            return
        }

        if let expectedLength, bodyCount != expectedLength {
            throw LumixError.http(
                0,
                "camera closed an incomplete media response (\(bodyCount) of \(expectedLength) bytes)"
            )
        }
    }
}

enum LumixMediaDownloadRetryPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }

        if case let LumixError.http(statusCode, message) = error {
            guard statusCode == 0 else { return false }
            let normalized = message.lowercased()
            return normalized.contains("incomplete") || normalized.contains("empty media response")
        }

        if let error = error as? POSIXDownloadError {
            return error.operation == "connect" || error.operation == "receive" || error.operation == "send"
        }

        return false
    }
}

private final class LegacyLumixDownloadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var isCancelled = false

    func register(_ fileDescriptor: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { throw CancellationError() }
        self.fileDescriptor = fileDescriptor
    }

    func unregister(_ fileDescriptor: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if self.fileDescriptor == fileDescriptor { self.fileDescriptor = -1 }
    }

    func cancel() {
        let shutdownDescriptor: Int32

        print("[GM1Sync] [LegacyMedia cancellation] operation.cancel enter.")
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            print("[GM1Sync] [LegacyMedia cancellation] operation.cancel exit; already cancelled.")
            return
        }
        isCancelled = true
        shutdownDescriptor = fileDescriptor >= 0 ? Darwin.dup(fileDescriptor) : -1
        lock.unlock()

        guard shutdownDescriptor >= 0 else {
            print("[GM1Sync] [LegacyMedia cancellation] operation.cancel exit; no active descriptor.")
            return
        }
        print(
            "[GM1Sync] [LegacyMedia cancellation] operation.cancel exit; " +
                "shutdown scheduled for duplicate fd=\(shutdownDescriptor)."
        )
        legacyLumixCancellationQueue.async {
            let shutdownResult = Darwin.shutdown(shutdownDescriptor, SHUT_RDWR)
            let shutdownError = shutdownResult == 0 ? 0 : errno
            print(
                "[GM1Sync] [LegacyMedia cancellation] shutdown completed " +
                    "fd=\(shutdownDescriptor) result=\(shutdownResult) errno=\(shutdownError)."
            )
            Darwin.close(shutdownDescriptor)
        }
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled || Task.isCancelled { throw CancellationError() }
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

final class CameraCapabilityParser: NSObject, XMLParserDelegate {
    private var model: String?
    private var version: String?
    private var date: String?
    private var currentMimeType: String?
    private var currentProfiles: Set<String> = []
    private var currentActions: [CameraContentAction] = []
    private var entries: [CameraCapabilityEntry] = []

    static func parse(_ data: Data) -> CameraCapabilities {
        let delegate = CameraCapabilityParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return CameraCapabilities(
            model: delegate.model,
            version: delegate.version,
            date: delegate.date,
            entries: delegate.entries
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        let attributes = Dictionary(uniqueKeysWithValues: attributeDict.map { ($0.key.lowercased(), $0.value) })

        switch name {
        case "contents_action_info":
            model = attributes["model"]
            version = attributes["version"]
            date = attributes["date"]
        case "content":
            currentMimeType = attributes["mime_type"]?.lowercased()
            currentProfiles = Set(
                (attributes["panasonic_com_pn"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                    .filter { !$0.isEmpty }
            )
            currentActions = []
        case "action" where currentMimeType != nil:
            guard let type = attributes["type"]?.nonEmpty else { return }
            let playerFunctions = Set(
                (attributes["player_func"] ?? "")
                    .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                    .map { String($0).lowercased() }
            )
            currentActions.append(
                CameraContentAction(
                    type: type,
                    enabled: Self.isAffirmative(attributes["enable"]),
                    operatingSystem: attributes["os"],
                    player: attributes["player"],
                    playerFunctions: playerFunctions
                )
            )
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
        guard name == "content", let currentMimeType else { return }
        entries.append(
            CameraCapabilityEntry(
                mimeType: currentMimeType,
                panasonicProfiles: currentProfiles,
                actions: currentActions
            )
        )
        self.currentMimeType = nil
        currentProfiles = []
        currentActions = []
    }

    private static func isAffirmative(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "yes", "true", "1", "on", "enable", "enabled": true
        default: false
        }
    }
}

final class DIDLParser: NSObject, XMLParserDelegate {
    private struct PendingResource {
        let url: URL
        let protocolInfo: String
        let attributes: [String: String]
    }

    private var itemID: String?
    private var title: String?
    private var itemClass: String?
    private var captureDate: Date?
    private var currentElement = ""
    private var currentText = ""
    private var currentProtocol = ""
    private var currentResourceAttributes: [String: String] = [:]
    private var pendingResources: [PendingResource] = []
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
        if elementName == "item" {
            itemID = attributeDict["id"]
            title = nil
            itemClass = nil
            captureDate = nil
            pendingResources = []
        }
        if elementName == "res" {
            currentProtocol = attributeDict["protocolInfo"] ?? ""
            currentResourceAttributes = attributeDict
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName.hasSuffix("title") { title = value }
        if elementName.hasSuffix("class") { itemClass = value }
        if elementName.hasSuffix("date") { captureDate = Self.parseCaptureDate(value) }
        if elementName == "res", let url = URL(string: value) {
            pendingResources.append(
                PendingResource(
                    url: url,
                    protocolInfo: currentProtocol,
                    attributes: currentResourceAttributes
                )
            )
            currentResourceAttributes = [:]
        }
        if elementName == "item" {
            resources.append(contentsOf: pendingResources.map { pending in
                let duration = Self.parseDuration(pending.attributes["duration"])
                let resolution = Self.parseResolution(pending.attributes["resolution"])
                let chapterList = pending.attributes.first { key, _ in
                    key.lowercased().hasSuffix("chapterlist")
                }?.value
                return LumixResource(
                    itemID: itemID,
                    title: title,
                    url: pending.url,
                    protocolInfo: pending.protocolInfo,
                    upnpClass: itemClass,
                    duration: duration,
                    resolutionWidth: resolution?.width,
                    resolutionHeight: resolution?.height,
                    size: pending.attributes["size"].flatMap(Int64.init),
                    bitrate: pending.attributes["bitrate"].flatMap(Int.init),
                    chapterList: chapterList,
                    captureDate: captureDate
                )
            })
            pendingResources = []
        }
        currentElement = ""
        currentText = ""
    }

    private static func parseCaptureDate(_ value: String) -> Date? {
        guard value.contains("T") || value.contains(":") else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) { return date }
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy:MM:dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func parseDuration(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3_600 + parts[1] * 60 + parts[2]
    }

    private static func parseResolution(_ value: String?) -> (width: Int, height: Int)? {
        guard let value else { return nil }
        let parts = value.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
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

    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
