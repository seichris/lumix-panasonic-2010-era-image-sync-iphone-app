import Foundation

// Camera-side location writing and clock commands for Image App-era cameras.
//
// The command chain, the binary track format, and the multipart framing come
// from the static analysis of Panasonic Image App 1.10.30 published in
// SahajJain01/lumix-local (docs/android-geotagging-findings.md). The camera
// does the matching and the writing; none of this has been confirmed on a
// GM1S yet, so every format detail below needs hardware validation.

// MARK: - Binary track

/// Panasonic's uploaded track: an 8-byte header (`01 00 00 00` + record count)
/// followed by 16-byte little-endian records.
enum LumixGeodata {
    /// Seconds between 1970-01-01 and 1980-01-06 00:00:00 UTC (the GPS epoch).
    /// Image App applies no leap-second correction, so neither do we.
    static let gpsEpochOffset: Int64 = 315_964_800
    static let noFixCoordinate: Int32 = 2_147_483_647
    static let noAltitude: Int16 = 32_767
    /// ASCII `A`: an ordinary logged sample.
    static let sampleFlag: UInt8 = 65
    /// ASCII `V`: Image App's stop/end marker.
    static let stopFlag: UInt8 = 86
    /// Image App's own storage limit.
    static let maximumRecords = 600_000
    /// A longer gap ends a segment, so the camera never bridges it.
    static let defaultSegmentGap: TimeInterval = 15 * 60
    static let headerLength = 8
    static let recordLength = 16

    struct Record: Equatable, Sendable {
        let gpsSeconds: Int32
        let latitudeE7: Int32
        let longitudeE7: Int32
        let altitude: Int16
        let flag: UInt8

        var date: Date {
            Date(timeIntervalSince1970: TimeInterval(Int64(gpsSeconds) + LumixGeodata.gpsEpochOffset))
        }

        var isStopMarker: Bool { flag == LumixGeodata.stopFlag }
        var latitude: Double? { latitudeE7 == LumixGeodata.noFixCoordinate ? nil : Double(latitudeE7) / 1e7 }
        var longitude: Double? { longitudeE7 == LumixGeodata.noFixCoordinate ? nil : Double(longitudeE7) / 1e7 }
    }

    enum EncodingError: LocalizedError, Equatable {
        case noSamples
        case timestampOutOfRange
        case invalidCoordinate
        case tooManyRecords(Int)
        case malformedPayload

        var errorDescription: String? {
            switch self {
            case .noSamples: return "No usable location samples fall in the selected period."
            case .timestampOutOfRange: return "A location sample has a time the camera cannot store."
            case .invalidCoordinate: return "A location sample has an invalid coordinate."
            case let .tooManyRecords(count):
                return "The track has \(count) records; the camera accepts at most \(LumixGeodata.maximumRecords)."
            case .malformedPayload: return "The location data is malformed."
            }
        }
    }

    /// Samples the app's own matcher would also trust, in time order, without duplicate timestamps.
    static func usableSamples(_ samples: [LocationSample], in period: ClosedRange<Date>? = nil) -> [LocationSample] {
        var seen = Set<Date>()
        return samples
            .filter { sample in
                sample.horizontalAccuracy >= 0
                    && sample.horizontalAccuracy <= LocationTrackMatcher.maximumUsableAccuracy
                    && sample.latitude.isFinite && sample.longitude.isFinite
                    && abs(sample.latitude) <= 90 && abs(sample.longitude) <= 180
                    && (period?.contains(sample.timestamp) ?? true)
            }
            .sorted { $0.timestamp < $1.timestamp }
            .filter { seen.insert($0.timestamp).inserted }
    }

    /// Splits time-ordered samples wherever consecutive samples are more than `maximumGap` apart.
    static func segments(
        of samples: [LocationSample],
        maximumGap: TimeInterval = defaultSegmentGap
    ) -> [[LocationSample]] {
        var segments: [[LocationSample]] = []
        var current: [LocationSample] = []
        for sample in samples {
            if let previous = current.last, sample.timestamp.timeIntervalSince(previous.timestamp) > maximumGap {
                segments.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Track records for the samples in `period`. Each segment ends with a `V`
    /// marker one second after its last sample, so the camera has an explicit
    /// end of the track instead of extending the last position.
    static func records(
        for samples: [LocationSample],
        in period: ClosedRange<Date>? = nil,
        maximumGap: TimeInterval = defaultSegmentGap
    ) throws -> [Record] {
        let usable = usableSamples(samples, in: period)
        guard !usable.isEmpty else { throw EncodingError.noSamples }
        var records: [Record] = []
        for segment in segments(of: usable, maximumGap: maximumGap) {
            for sample in segment {
                records.append(try record(for: sample))
            }
            if let last = segment.last {
                records.append(Record(
                    gpsSeconds: try gpsSeconds(for: last.timestamp.addingTimeInterval(1)),
                    latitudeE7: noFixCoordinate,
                    longitudeE7: noFixCoordinate,
                    altitude: noAltitude,
                    flag: stopFlag
                ))
            }
        }
        guard records.count <= maximumRecords else { throw EncodingError.tooManyRecords(records.count) }
        return records
    }

    static func record(for sample: LocationSample) throws -> Record {
        guard sample.latitude.isFinite, sample.longitude.isFinite,
              abs(sample.latitude) <= 90, abs(sample.longitude) <= 180 else {
            throw EncodingError.invalidCoordinate
        }
        return Record(
            gpsSeconds: try gpsSeconds(for: sample.timestamp),
            // Int32(Double) truncates toward zero, matching Image App's Java cast.
            latitudeE7: Int32(sample.latitude * 1e7),
            longitudeE7: Int32(sample.longitude * 1e7),
            altitude: altitude(sample.altitude),
            flag: sampleFlag
        )
    }

    /// Image App writes `(short)Location.getAltitude()`, which is 0 when a fix has
    /// no altitude; imported Google Timeline samples also carry 0. Values are
    /// clamped rather than wrapped, and 32767 stays reserved for "no altitude".
    static func altitude(_ metres: Double) -> Int16 {
        guard metres.isFinite else { return 0 }
        let truncated = metres.rounded(.towardZero)
        if truncated >= Double(noAltitude) { return noAltitude - 1 }
        if truncated <= Double(Int16.min) { return Int16.min }
        return Int16(truncated)
    }

    static func gpsSeconds(for date: Date) throws -> Int32 {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else { throw EncodingError.timestampOutOfRange }
        let seconds = Int64(interval.rounded(.down)) - gpsEpochOffset
        guard seconds >= 0, seconds <= Int64(Int32.max) else { throw EncodingError.timestampOutOfRange }
        return Int32(seconds)
    }

    static func encode(_ records: [Record]) throws -> Data {
        guard !records.isEmpty else { throw EncodingError.noSamples }
        guard records.count <= maximumRecords else { throw EncodingError.tooManyRecords(records.count) }
        var data = Data(capacity: headerLength + records.count * recordLength)
        data.appendLittleEndian(Int32(1))
        data.appendLittleEndian(Int32(records.count))
        for record in records {
            data.appendLittleEndian(record.gpsSeconds)
            data.appendLittleEndian(record.latitudeE7)
            data.appendLittleEndian(record.longitudeE7)
            data.appendLittleEndian(record.altitude)
            data.append(record.flag)
            data.append(0)
        }
        return data
    }

    static func decode(_ data: Data) throws -> [Record] {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength,
              bytes.readLittleEndianInt32(at: 0) == 1,
              let count = bytes.readLittleEndianInt32(at: 4), count >= 0,
              bytes.count == headerLength + Int(count) * recordLength else {
            throw EncodingError.malformedPayload
        }
        return (0..<Int(count)).map { index in
            let offset = headerLength + index * recordLength
            return Record(
                gpsSeconds: bytes.readLittleEndianInt32(at: offset) ?? 0,
                latitudeE7: bytes.readLittleEndianInt32(at: offset + 4) ?? 0,
                longitudeE7: bytes.readLittleEndianInt32(at: offset + 8) ?? 0,
                altitude: Int16(bitPattern: UInt16(bytes[offset + 12]) | UInt16(bytes[offset + 13]) << 8),
                flag: bytes[offset + 14]
            )
        }
    }
}

/// Image App's multipart framing for `cam.cgi?mode=senddata&value2=1`, reproduced
/// byte for byte: one part, and the closing boundary directly after the payload
/// with no CRLF in between. Whether the GM1S needs this exact shape is unverified.
enum LumixGeodataUpload {
    static let boundary = "xyzxyz"
    static let contentType = "multipart/form-data; boundary=\(boundary)"

    static func body(for payload: Data) -> Data {
        let headerLines: [String] = [
            "--\(boundary)",
            "Content-Disposition: form-data; name=\"filename\"; filename=\"bindata.bin\"",
            "Content-Type: application/octet-stream",
            "Content-Transfer-Encoding: binary",
            "Content-Length: \(payload.count)",
            "",
            ""
        ]
        var body = Data(headerLines.joined(separator: "\r\n").utf8)
        body.append(payload)
        body.append(Data("--\(boundary)--".utf8))
        return body
    }
}

// MARK: - Clock values

/// `YYYYMMDDhhmmss±HHMM`: the UTC date and time plus the time zone's raw
/// (standard, non-daylight-saving) offset, as Image App builds it for both
/// `setsetting&type=clock` and `notify&type=clock`.
enum LumixCameraClock {
    static let offsetRange = -720...840

    enum ClockError: LocalizedError, Equatable {
        case offsetOutOfRange(Int)

        var errorDescription: String? {
            "The time zone offset is outside the range the camera accepts."
        }
    }

    /// Java's `TimeZone.getRawOffset()`: the standard offset without daylight saving.
    static func rawOffsetMinutes(of timeZone: TimeZone, at date: Date) -> Int {
        (timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date))) / 60
    }

    static func value(for date: Date, timeZone: TimeZone) throws -> String {
        try value(for: date, offsetMinutes: rawOffsetMinutes(of: timeZone, at: date))
    }

    static func value(for date: Date, offsetMinutes: Int) throws -> String {
        guard offsetRange.contains(offsetMinutes) else { throw ClockError.offsetOutOfRange(offsetMinutes) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let sign = offsetMinutes < 0 ? "-" : "+"
        return String(
            format: "%04d%02d%02d%02d%02d%02d%@%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            sign, abs(offsetMinutes) / 60, abs(offsetMinutes) % 60
        )
    }

    /// The next whole minute after `date`. Image App sets the clock on a minute
    /// boundary, so the camera starts the minute with zero seconds.
    static func nextMinuteBoundary(after date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 60).rounded(.down) * 60 + 60)
    }

    /// A `cam.cgi` query with the value percent-encoded. URLQueryItem leaves `+`
    /// unencoded, and a CGI parser may read a raw `+` as a space, so the first
    /// attempt sends `%2B`; the raw form is kept for a single fallback.
    static func percentEncodedQuery(mode: String, type: String, value: String, encodePlus: Bool) -> String {
        let encodedValue = encodePlus ? value.replacingOccurrences(of: "+", with: "%2B") : value
        return "mode=\(mode)&type=\(type)&value=\(encodedValue)"
    }
}

/// The reply to `getsetting&type=clock`. Its format has not been confirmed on
/// a GM1S, so the raw text is always kept.
struct LumixCameraClockReading: Equatable, Sendable {
    let raw: String
    /// Interpreted the way the camera accepts the value: UTC fields plus offset.
    let utcDate: Date?
    let offsetMinutes: Int?

    init?(reply: LumixCommandReply) {
        guard reply.isOK else { return nil }
        let node = reply.xml?.firstDescendant(named: "settingvalue")
        let text = node?.attribute("clock") ?? node?.trimmedText.nonEmptyValue ?? reply.fields.dropFirst().first
        guard let text, !text.isEmpty else { return nil }
        self.init(raw: text)
    }

    init(raw: String) {
        self.raw = raw
        let digits = raw.prefix { $0.isNumber }
        var date: Date?
        if digits.count >= 14 {
            let string = String(digits.prefix(14))
            func part(_ start: Int, _ length: Int) -> Int? {
                let lower = string.index(string.startIndex, offsetBy: start)
                return Int(string[lower..<string.index(lower, offsetBy: length)])
            }
            var components = DateComponents()
            components.year = part(0, 4)
            components.month = part(4, 2)
            components.day = part(6, 2)
            components.hour = part(8, 2)
            components.minute = part(10, 2)
            components.second = part(12, 2)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            // Reject impossible dates such as month 13 instead of letting Calendar roll them over.
            if let value = calendar.date(from: components),
               calendar.dateComponents([.month, .day, .hour, .minute], from: value)
                == DateComponents(month: components.month, day: components.day,
                                  hour: components.hour, minute: components.minute) {
                date = value
            }
        }
        utcDate = date
        let remainder = raw.dropFirst(digits.count)
        if let sign = remainder.first, sign == "+" || sign == "-",
           remainder.dropFirst().count == 4, let value = Int(remainder.dropFirst()) {
            let minutes = (value / 100) * 60 + value % 100
            offsetMinutes = sign == "-" ? -minutes : minutes
        } else {
            offsetMinutes = nil
        }
    }

    /// Camera time minus phone time, assuming the reply uses the same UTC-plus-offset
    /// convention as the value the camera accepts.
    func difference(from phoneTime: Date) -> TimeInterval? {
        utcDate.map { $0.timeIntervalSince(phoneTime) }
    }
}

// MARK: - Write progress and capability

/// `getprogress&type=add_location_data`: `<result>`, `<state>`, `<progress>`, `<err>`.
struct LumixLocationWriteProgress: Equatable, Sendable {
    enum State: String, Sendable {
        case prepare
        case exec
        case finish
        case error
        case unknown
    }

    let result: String
    let state: State
    let rawState: String
    let progress: Int?
    let error: String?

    init(reply: LumixCommandReply) {
        result = reply.result
        rawState = reply.xml?.childText("state")?.lowercased() ?? ""
        state = State(rawValue: rawState) ?? .unknown
        progress = reply.xml?.childText("progress").flatMap { Int($0) }
        error = reply.xml?.childText("err")?.lowercased().nonEmptyValue
    }

    var isCancelled: Bool { state == .error && error == "cancel" }
}

enum LumixGeodataReplies {
    /// `startsenddata` must answer `ok` and announce a single upload (`<method>once</method>`).
    static func acceptsSingleUpload(_ reply: LumixCommandReply) -> Bool {
        reply.isOK && reply.xml?.firstDescendant(named: "method")?.trimmedText.lowercased() == "once"
    }
}

/// Whether the connected camera can be asked to write uploaded locations.
enum CameraLocationWriteSupport: Equatable, Sendable {
    case supported(evidence: String)
    case unsupported(reason: String)
    case unknown

    /// Models for which Panasonic's iOS Image App help documents the app-triggered
    /// "Write" step after sending location data.
    static let documentedModels: Set<String> = [
        "FT7", "TS7", "GF10", "TZ90", "TZ91", "TZ92", "TZ93", "ZS70", "FZ80", "FZ82", "GF9", "GX800",
        "GX850", "FZ2000", "FZ2500", "LX9", "LX10", "LX15", "G80", "G81", "G85", "GX80", "GX85",
        "GF8", "TZ100", "TZ101", "TZ110", "ZS100", "ZS110", "TZ80", "TZ81", "ZS60", "FZ300",
        "FZ330", "GX8", "G7", "G70", "GF7", "TZ70", "TZ71", "ZS50", "GM5", "GM1S", "LX100",
        "FZ1000", "GH4"
    ]

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// Image App enables the write step when the camera advertises
    /// `geotag_add_enable` or reports protocol version 1.3 or newer. Panasonic's
    /// documented model list is accepted as weaker evidence.
    static func evaluate(_ capabilities: CameraCapabilities?) -> CameraLocationWriteSupport {
        guard let capabilities else { return .unknown }
        if capabilities.specs.contains("geotag_add_enable") {
            return .supported(evidence: "The camera advertises geotag_add_enable.")
        }
        if let version = capabilities.protocolVersion, versionAtLeast(version, major: 1, minor: 3) {
            return .supported(evidence: "The camera reports protocol \(version) (1.3 or newer).")
        }
        if let model = normalizedModel(capabilities.productModelName ?? capabilities.model),
           documentedModels.contains(model) {
            return .supported(evidence: "Panasonic documents app-triggered location writing for the \(model).")
        }
        return .unsupported(reason: "The camera does not report support for writing location data from the app.")
    }

    static func normalizedModel(_ name: String?) -> String? {
        guard var model = name?.uppercased().replacingOccurrences(of: " ", with: ""), !model.isEmpty else { return nil }
        for prefix in ["DMC-", "DC-"] where model.hasPrefix(prefix) { model.removeFirst(prefix.count) }
        return model
    }

    static func versionAtLeast(_ version: String, major: Int, minor: Int) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let actualMajor = parts.first ?? 0
        let actualMinor = parts.count > 1 ? parts[1] : 0
        return actualMajor > major || (actualMajor == major && actualMinor >= minor)
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func readLittleEndianInt32(at offset: Int) -> Int32? {
        guard offset + 3 < count else { return nil }
        let value = UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
        return Int32(bitPattern: value)
    }
}
