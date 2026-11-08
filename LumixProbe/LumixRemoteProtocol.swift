import Foundation

// Pure helpers for the Image App-era `cam.cgi` control protocol. Nothing in this
// file performs network I/O, so every parser can be exercised with fixtures.
//
// Sources: Panasonic Image App behavior as documented by gphoto/libgphoto2
// (camlibs/lumix), peci1/lumix-link-desktop, and the GX80 traffic captures and
// Image App 1.10.30 analysis published by SahajJain01/lumix-local. GM1S-specific
// behavior must still be confirmed on hardware; see COMPATIBILITY.md.

// MARK: - Minimal XML tree

/// A small immutable XML tree used for camera replies.
struct LumixXMLNode: Equatable, Sendable {
    var name: String
    var attributes: [String: String]
    var text: String
    var children: [LumixXMLNode]

    /// The element name without a namespace prefix (`dc:title` → `title`).
    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func child(_ name: String) -> LumixXMLNode? {
        children.first { $0.matches(name) }
    }

    func children(named name: String) -> [LumixXMLNode] {
        children.filter { $0.matches(name) }
    }

    func childText(_ name: String) -> String? {
        child(name)?.trimmedText
    }

    func firstDescendant(named name: String) -> LumixXMLNode? {
        for child in children {
            if child.matches(name) { return child }
            if let match = child.firstDescendant(named: name) { return match }
        }
        return nil
    }

    func descendants(named name: String) -> [LumixXMLNode] {
        var result: [LumixXMLNode] = []
        for child in children {
            if child.matches(name) { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }

    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        return attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func matches(_ candidate: String) -> Bool {
        name == candidate || localName == candidate
    }
}

enum LumixXML {
    /// Parses well-formed XML. Returns `nil` for malformed documents so callers
    /// can fall back to lenient extraction.
    static func parse(_ data: Data) -> LumixXMLNode? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return parse(text)
    }

    static func parse(_ text: String) -> LumixXMLNode? {
        // XMLParser rejects a declaration preceded by whitespace or a byte-order mark.
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        guard trimmed.hasPrefix("<"), let data = trimmed.data(using: .utf8) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        private var stack: [LumixXMLNode] = [LumixXMLNode(name: "#document", attributes: [:], text: "", children: [])]

        var root: LumixXMLNode? { stack.first?.children.first }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            stack.append(LumixXMLNode(name: elementName, attributes: attributeDict, text: "", children: []))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard stack.count > 1 else { return }
            let node = stack.removeLast()
            stack[stack.count - 1].children.append(node)
        }
    }
}

// MARK: - Commands and replies

/// One `cam.cgi` request. Parameters keep Panasonic's `mode, type, value, value2` order.
struct LumixCommand: Hashable, Sendable, CustomStringConvertible {
    let mode: String
    let type: String?
    let value: String?
    let value2: String?

    init(mode: String, type: String? = nil, value: String? = nil, value2: String? = nil) {
        self.mode = mode
        self.type = type
        self.value = value
        self.value2 = value2
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "mode", value: mode)]
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        if let value { items.append(URLQueryItem(name: "value", value: value)) }
        if let value2 { items.append(URLQueryItem(name: "value2", value: value2)) }
        return items
    }

    var description: String {
        queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    static let getState = LumixCommand(mode: "getstate")
    static let recordMode = camcmd("recmode")
    static let playbackMode = camcmd("playmode")
    static let stopStream = LumixCommand(mode: "stopstream")
    static let capture = camcmd("capture")
    static let captureCancel = camcmd("capture_cancel")
    static let videoRecordStart = camcmd("video_recstart")
    static let videoRecordStop = camcmd("video_recstop")
    static let oneShotAutofocus = camcmd("oneshot_af")

    static func camcmd(_ value: String) -> LumixCommand {
        LumixCommand(mode: "camcmd", value: value)
    }

    static func startStream(port: UInt16) -> LumixCommand {
        LumixCommand(mode: "startstream", value: String(port))
    }

    static func requestAccess(identifier: String, clientName: String) -> LumixCommand {
        LumixCommand(mode: "accctrl", type: "req_acc", value: identifier, value2: clientName)
    }

    static func getSetting(_ type: String) -> LumixCommand {
        LumixCommand(mode: "getsetting", type: type)
    }

    static func setSetting(_ type: String, value: String, value2: String? = nil) -> LumixCommand {
        LumixCommand(mode: "setsetting", type: type, value: value, value2: value2)
    }

    static func getInfo(_ type: String) -> LumixCommand {
        LumixCommand(mode: "getinfo", type: type)
    }

    static func camctrl(_ type: String, value: String, value2: String? = nil) -> LumixCommand {
        LumixCommand(mode: "camctrl", type: type, value: value, value2: value2)
    }
}

/// Human-readable meanings of the result codes seen in cam.cgi replies.
enum LumixResultCode {
    static let ok = "ok"
    static let busy = "err_busy"
    static let retry = "err_retry"
    static let awaitingApproval = "ok_under_research"
    static let noReply = "no_reply"

    static func message(for code: String) -> String {
        switch code {
        case "err_already_connected":
            return "Another device, probably Panasonic Image App, is controlling the camera. Disconnect it and try again."
        case "err_busy": return "The camera is busy."
        case "err_retry": return "The camera is still exposing."
        case "err_param": return "The camera does not support that command or value."
        case "err_non_support": return "The camera does not support that in its current mode."
        case "err_critical": return "The camera rejected the command."
        case "err_reject": return "The camera rejected the command in its current state."
        case "err_unsuitable_app": return "The camera refused this app."
        case "err_user_refused": return "The connection was declined on the camera."
        case "err_noremain": return "The memory card is full."
        case "err_sdcard_access": return "The camera reported a memory card error."
        case "err_sdcard_write_protected": return "The memory card is write-protected."
        case "err_temperature": return "The camera is too hot."
        case "err_others_requesting": return "Another device is requesting access to the camera."
        case "ok_under_research": return "Accept the connection on the camera."
        case "no_reply": return "The camera did not reply."
        default: return "The camera replied \(code)."
        }
    }
}

/// A parsed cam.cgi reply. Cameras answer either with XML
/// (`<camrply><result>ok</result>…</camrply>`) or with CSV (`ok,a,b`).
struct LumixCommandReply: Equatable, Sendable {
    let raw: String
    let result: String
    /// CSV fields, including the result in position 0. Empty for XML replies.
    let fields: [String]
    let xml: LumixXMLNode?

    var isOK: Bool { result.caseInsensitiveCompare(LumixResultCode.ok) == .orderedSame }
    var isBusy: Bool { result == LumixResultCode.busy }
    var isAwaitingCameraApproval: Bool { result == LumixResultCode.awaitingApproval }

    static func parse(_ data: Data) -> LumixCommandReply {
        parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> LumixCommandReply {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
        guard !trimmed.isEmpty else {
            return LumixCommandReply(raw: text, result: LumixResultCode.noReply, fields: [], xml: nil)
        }
        if trimmed.hasPrefix("<") {
            if let root = LumixXML.parse(trimmed) {
                let result = root.childText("result") ?? root.firstDescendant(named: "result")?.trimmedText
                return LumixCommandReply(raw: text, result: result?.nonEmptyValue ?? "bad_xml", fields: [], xml: root)
            }
            // Some firmware emits slightly malformed XML; recover the result code.
            let result = trimmed.firstCapture(of: "<result>([^<]*)</result>")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LumixCommandReply(raw: text, result: result?.nonEmptyValue ?? "bad_xml", fields: [], xml: nil)
        }
        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return LumixCommandReply(raw: text, result: fields.first ?? LumixResultCode.noReply, fields: fields, xml: nil)
    }
}

// MARK: - State

enum LumixCameraMode: String, Equatable, Sendable {
    case record = "rec"
    case playback = "play"
}

/// The camera's `getstate` snapshot.
struct LumixCameraState: Equatable, Sendable {
    let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    init?(reply: LumixCommandReply) {
        guard reply.isOK, let state = reply.xml?.child("state") else { return nil }
        var values: [String: String] = [:]
        for child in state.children {
            values[child.name] = child.trimmedText
        }
        self.values = values
    }

    var mode: LumixCameraMode? { values["cammode"].flatMap(LumixCameraMode.init(rawValue:)) }

    /// Battery level as `(level, maximum)`; `nil` when no battery is reported.
    var battery: (level: Int, maximum: Int)? {
        guard let parts = values["batt"]?.split(separator: "/"), parts.count == 2,
              let level = Int(parts[0]), let maximum = Int(parts[1]), maximum > 0, level >= 0 else { return nil }
        return (level, maximum)
    }

    var remainingPhotos: Int? { values["remaincapacity"].flatMap { Int($0) } }
    var remainingVideoSeconds: Int? { values["video_remaincapacity"].flatMap { Int($0) } }
    var isRecordingVideo: Bool { values["rec"] == "on" }
    var isAccessingCard: Bool { values["sd_access"] == "on" }
    var cardStatus: String? { values["sdcardstatus"] }
    var hasCard: Bool? { values["sd_memory"].map { $0 == "set" } }
    var temperature: String? { values["temperature"] }
    var firmwareVersion: String? { values["version"] }
    var videoProgressSeconds: Int? { values["progress_time"].flatMap { Int($0) } }

    var isCardWritable: Bool? {
        guard let cardStatus else { return nil }
        return cardStatus == "write_enable"
    }
}

/// `<settingvalue iso="auto">` from a `getsetting` reply.
struct LumixSettingValue: Equatable, Sendable {
    let type: String
    let value: String
    let attributes: [String: String]

    init(type: String, value: String, attributes: [String: String] = [:]) {
        self.type = type
        self.value = value
        self.attributes = attributes
    }

    init?(reply: LumixCommandReply, type: String) {
        guard reply.isOK, let node = reply.xml?.firstDescendant(named: "settingvalue") else { return nil }
        guard let value = node.attribute(type) ?? node.trimmedText.nonEmptyValue else { return nil }
        self.type = type
        self.value = value
        var attributes = node.attributes
        attributes.removeValue(forKey: type)
        self.attributes = attributes
    }
}

/// Manual-focus feedback: `ok,<position>,<maximum>`.
struct LumixFocusPosition: Equatable, Sendable {
    let position: Int
    let maximum: Int

    init(position: Int, maximum: Int) {
        self.position = position
        self.maximum = maximum
    }

    init?(reply: LumixCommandReply) {
        guard reply.isOK, reply.fields.count >= 3,
              let position = Int(reply.fields[1]), let maximum = Int(reply.fields[2]), maximum > 0 else { return nil }
        self.init(position: position, maximum: maximum)
    }

    var fraction: Double { min(1, max(0, Double(position) / Double(maximum))) }
}

// MARK: - Lens and APEX values

/// `getinfo&type=lens`, e.g. `ok,2304/256,1094/256,3584/256,-1536/256,0,on,42,14,on,128/1024,on`.
struct LumixLensInfo: Equatable, Sendable {
    /// Smallest aperture (largest f-number) as an APEX value.
    let apertureClosed: Double?
    /// Widest aperture at the current focal length as an APEX value.
    let apertureOpen: Double?
    let shutterFastest: Double?
    /// Slowest timed shutter speed as an APEX value.
    let shutterSlowest: Double?
    /// The camera also offers Bulb in this mode. The app does not offer it.
    let offersBulb: Bool
    let maximumFocalLength: Int?
    let minimumFocalLength: Int?
    let rawFields: [String]

    /// 60 s: the slowest timed speed a GM1S reports in P, A and S.
    static let slowestTimedShutter: Double = -6

    init?(reply: LumixCommandReply) {
        let fields = reply.fields
        guard reply.isOK, fields.count >= 5 else { return nil }
        apertureClosed = LumixAPEX.parse(fields[1])
        apertureOpen = LumixAPEX.parse(fields[2])
        shutterFastest = LumixAPEX.parse(fields[3])
        // In M a GM1S reports `16384/256` (Tv 64) as the slowest speed instead of
        // 60 s. No timed speed is faster than the fastest one, so that value
        // stands for Bulb, and the timed speeds still end at 60 s.
        let slowest = LumixAPEX.parse(fields[4])
        if let slowest, slowest > (shutterFastest ?? 20) {
            shutterSlowest = Self.slowestTimedShutter
            offersBulb = true
        } else {
            shutterSlowest = slowest
            offersBulb = false
        }
        maximumFocalLength = fields.count > 7 ? Int(fields[7]) : nil
        minimumFocalLength = fields.count > 8 ? Int(fields[8]) : nil
        rawFields = Array(fields.dropFirst())
    }

    /// True when the lens reports a focal-length range (a zoom lens).
    var hasFocalLengthRange: Bool {
        guard let maximumFocalLength, let minimumFocalLength else { return false }
        return maximumFocalLength > minimumFocalLength
    }
}

/// One selectable aperture or shutter value.
struct LumixExposureOption: Hashable, Identifiable, Sendable {
    let value: String
    let label: String
    let apex: Double

    var id: String { value }
}

/// Panasonic expresses aperture and shutter as `N/256` APEX values:
/// aperture `Av = 2·log2(f-number)` and shutter `Tv = log2(1/seconds)`.
enum LumixAPEX {
    private static let apertureThirds = [
        "1.0", "1.1", "1.2", "1.4", "1.6", "1.8", "2.0", "2.2", "2.5", "2.8", "3.2", "3.5",
        "4.0", "4.5", "5.0", "5.6", "6.3", "7.1", "8", "9", "10", "11", "13", "14", "16",
        "18", "20", "22", "25", "29", "32"
    ]
    private static let fastShutterThirds = [
        "1", "1.3", "1.6", "2", "2.5", "3.2", "4", "5", "6", "8", "10", "13", "15", "20", "25",
        "30", "40", "50", "60", "80", "100", "125", "160", "200", "250", "320", "400", "500",
        "640", "800", "1000", "1300", "1600", "2000", "2500", "3200", "4000", "5000", "6400",
        "8000", "10000", "13000", "16000"
    ]
    private static let slowShutterThirds = [
        "1", "1.3", "1.6", "2", "2.5", "3.2", "4", "5", "6", "8", "10", "13", "15", "20", "25",
        "30", "40", "50", "60"
    ]

    static func parse(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            guard let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 else {
                return nil
            }
            return numerator / denominator
        }
        return Double(value)
    }

    static func encode(_ apex: Double) -> String {
        "\(Int((apex * 256).rounded()))/256"
    }

    static func thirdStopValue(_ thirds: Int) -> String {
        "\(Int((Double(thirds) * 256 / 3).rounded()))/256"
    }

    static func apertureLabel(_ apex: Double?) -> String {
        guard let apex, apex.isFinite else { return "–" }
        let thirds = apex * 3
        let index = Int(thirds.rounded())
        if abs(thirds - Double(index)) < 0.08, apertureThirds.indices.contains(index) {
            return "f/" + apertureThirds[index]
        }
        let fNumber = pow(2, apex / 2)
        return fNumber < 10 ? String(format: "f/%.1f", fNumber) : String(format: "f/%.0f", fNumber)
    }

    static func shutterLabel(_ apex: Double?) -> String {
        guard let apex, apex.isFinite else { return "–" }
        let thirds = apex * 3
        let index = Int(thirds.rounded())
        if abs(thirds - Double(index)) < 0.08 {
            if index > 0, fastShutterThirds.indices.contains(index) { return "1/" + fastShutterThirds[index] }
            if index == 0 { return "1\"" }
            if index < 0, slowShutterThirds.indices.contains(-index) { return slowShutterThirds[-index] + "\"" }
        }
        let seconds = pow(2, -apex)
        if seconds >= 0.95 {
            let text = String(format: "%.1f", seconds)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "\""
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    /// Exposure compensation such as `-4/3` → `−1⅓`.
    static func compensationLabel(_ value: String) -> String {
        guard let number = parse(value) else { return value }
        return compensationLabel(thirds: Int((number * 3).rounded()))
    }

    static func compensationLabel(thirds: Int) -> String {
        if thirds == 0 { return "±0" }
        let sign = thirds > 0 ? "+" : "−"
        let whole = abs(thirds) / 3
        let fraction = ["", "⅓", "⅔"][abs(thirds) % 3]
        return sign + (whole > 0 || fraction.isEmpty ? String(whole) : "") + fraction
    }

    static func apertureOptions(open: Double, closed: Double) -> [LumixExposureOption] {
        guard open.isFinite, closed.isFinite, closed >= open else { return [] }
        var options = [LumixExposureOption(value: encode(open), label: apertureLabel(open), apex: open)]
        let first = Int((open * 3 + 0.1).rounded(.down)) + 1
        let last = Int((closed * 3 + 0.1).rounded(.down))
        if first <= last {
            for thirds in first...last {
                let apex = Double(thirds) / 3
                options.append(LumixExposureOption(value: thirdStopValue(thirds), label: apertureLabel(apex), apex: apex))
            }
        }
        return options
    }

    static func shutterOptions(fastest: Double, slowest: Double) -> [LumixExposureOption] {
        guard fastest.isFinite, slowest.isFinite, fastest >= slowest else { return [] }
        let first = Int((slowest * 3 - 0.1).rounded(.up))
        let last = Int((fastest * 3 + 0.1).rounded(.down))
        guard first <= last else { return [] }
        return (first...last).map { thirds in
            let apex = Double(thirds) / 3
            return LumixExposureOption(value: thirdStopValue(thirds), label: shutterLabel(apex), apex: apex)
        }
    }
}

// MARK: - Menus

/// One entry of `getinfo&type=allmenu`. Option lists live under `<group>`,
/// submenus under `<menu>`; both become `children`.
struct LumixMenuItem: Equatable, Sendable {
    let id: String
    let title: String
    let functionType: String?
    let commandMode: String?
    let commandType: String?
    let commandValue: String?
    let commandValue2: String?
    let children: [LumixMenuItem]

    /// Options whose value is a placeholder (`__value__`) need extra input such as a
    /// colour temperature; the remote screen does not offer them yet.
    var requiresAdditionalValue: Bool {
        (commandValue ?? "").contains("__value__") || (commandValue2 ?? "").contains("__value__")
    }
}

/// The static menu tree from `getinfo&type=allmenu`.
struct LumixMenuSchema: Equatable, Sendable {
    let model: String?
    let itemsByID: [String: LumixMenuItem]

    func item(_ id: String) -> LumixMenuItem? { itemsByID[id] }

    static func parse(_ data: Data) -> LumixMenuSchema? {
        guard let root = LumixXML.parse(data), let menuset = root.firstDescendant(named: "menuset") else {
            return nil
        }
        var titles: [String: String] = [:]
        if let titleList = menuset.child("titlelist") {
            let languages = titleList.children(named: "language")
            let language = languages.first { $0.attribute("default") == "yes" } ?? languages.first
            for title in language?.children(named: "title") ?? [] {
                if let id = title.attribute("id") { titles[id] = title.trimmedText }
            }
        }

        var itemsByID: [String: LumixMenuItem] = [:]
        func build(_ node: LumixXMLNode) -> LumixMenuItem {
            var children: [LumixMenuItem] = []
            for container in node.children where container.name == "menu" || container.name == "group" {
                children.append(contentsOf: container.children(named: "item").map(build))
            }
            let titleID = node.attribute("title_id") ?? ""
            let item = LumixMenuItem(
                id: node.attribute("id") ?? "",
                title: titles[titleID] ?? titleID,
                functionType: node.attribute("func_type"),
                commandMode: node.attribute("cmd_mode"),
                commandType: node.attribute("cmd_type"),
                commandValue: node.attribute("cmd_value"),
                commandValue2: node.attribute("cmd_value2"),
                children: children
            )
            // The same id can appear in several sections; keep the most complete one.
            if !item.id.isEmpty, itemsByID[item.id] == nil || (itemsByID[item.id]?.children.isEmpty == true && !children.isEmpty) {
                itemsByID[item.id] = item
            }
            return item
        }

        for section in menuset.children where section.name != "titlelist" {
            for menu in section.children(named: "menu") {
                for item in menu.children(named: "item") { _ = build(item) }
            }
        }
        guard !itemsByID.isEmpty else { return nil }
        return LumixMenuSchema(model: menuset.attribute("model"), itemsByID: itemsByID)
    }
}

/// Enable flags and current values from `getinfo&type=curmenu`.
///
/// Parsed with a lenient scanner: the GX80 has been seen emitting malformed XML
/// here (`enable="no" /0`), and one bad attribute must not hide every control.
struct LumixCurrentMenu: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let isEnabled: Bool
        let value: String?
    }

    let entries: [String: Entry]

    static func parse(_ text: String) -> LumixCurrentMenu {
        var entries: [String: Entry] = [:]
        for attributes in text.captures(of: "<item\\s+([^>]*?)/?>") {
            var values: [String: String] = [:]
            for pair in attributes.capturePairs(of: "(\\w+)=\"([^\"]*)\"") {
                values[pair.0] = pair.1
            }
            guard let id = values["id"] else { continue }
            entries[id] = Entry(isEnabled: values["enable"].map { $0 == "yes" } ?? true, value: values["value"])
        }
        return LumixCurrentMenu(entries: entries)
    }

    func isEnabled(_ id: String, default defaultValue: Bool = true) -> Bool {
        entries[id]?.isEnabled ?? defaultValue
    }

    func value(_ id: String) -> String? { entries[id]?.value }

    /// The mode dial position, inferred from which exposure controls are enabled.
    var exposureMode: LumixExposureMode {
        func enabled(_ id: String) -> Bool { entries[id]?.isEnabled == true }
        if entries.isEmpty { return .unknown }
        if enabled("menu_item_id_f_and_ss") { return .manual }
        if enabled("menu_item_id_shutter_speed") || enabled("menu_item_id_ss") { return .shutterPriority }
        if enabled("menu_item_id_aperture") || enabled("menu_item_id_f") { return .aperturePriority }
        if enabled("menu_item_id_program_shift") { return .program }
        return .automatic
    }
}

enum LumixExposureMode: String, Equatable, Sendable {
    case program = "P"
    case aperturePriority = "A"
    case shutterPriority = "S"
    case manual = "M"
    case automatic = "Auto"
    case unknown = "?"

    var allowsApertureChange: Bool { self == .aperturePriority || self == .manual }
    var allowsShutterChange: Bool { self == .shutterPriority || self == .manual }
}

// MARK: - String helpers

extension String {
    var nonEmptyValue: String? { isEmpty ? nil : self }

    func firstCapture(of pattern: String) -> String? {
        captures(of: pattern).first
    }

    func captures(of pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[capture])
        }
    }

    func capturePairs(of pattern: String) -> [(String, String)] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 2,
                  let first = Range(match.range(at: 1), in: self),
                  let second = Range(match.range(at: 2), in: self) else { return nil }
            return (String(self[first]), String(self[second]))
        }
    }
}
