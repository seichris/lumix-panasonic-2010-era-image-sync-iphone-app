import Foundation

/// A scripted camera for UI tests and previews of location writing and clock
/// setting. It validates the uploaded track like a camera would and never
/// touches a network.
actor DemoGeotagCamera: CameraGeotagControlling {
    nonisolated let host = "192.168.54.1"
    nonisolated var belongsToCurrentConnection: Bool { true }

    private var expectedUploadLength: Int?
    private var uploadedRecords: [LumixGeodata.Record] = []
    private var writeState: String?
    private var progressPolls = 0
    private var clockValue = "20260101000000+0000"

    func perform(_ command: LumixCommand, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply {
        try await Task.sleep(for: .milliseconds(20))
        return LumixCommandReply.parse(reply(to: command))
    }

    func perform(
        percentEncodedQuery: String,
        body: Data?,
        contentType: String?,
        timeoutInterval: TimeInterval?
    ) async throws -> LumixCommandReply {
        try await Task.sleep(for: .milliseconds(20))
        if let body {
            guard percentEncodedQuery == "mode=senddata&value2=1", let expectedUploadLength,
                  let payload = Self.payload(in: body), payload.count == expectedUploadLength,
                  let records = try? LumixGeodata.decode(payload) else {
                return LumixCommandReply.parse(Self.result("err_param"))
            }
            uploadedRecords = records
            return LumixCommandReply.parse(Self.result("ok"))
        }
        if percentEncodedQuery.hasPrefix("mode=notify&type=clock&value=") {
            return LumixCommandReply.parse(Self.result("ok"))
        }
        if percentEncodedQuery.hasPrefix("mode=setsetting&type=clock&value=") {
            clockValue = String(percentEncodedQuery.dropFirst("mode=setsetting&type=clock&value=".count))
                .replacingOccurrences(of: "%2B", with: "+")
            return LumixCommandReply.parse(Self.result("ok"))
        }
        return LumixCommandReply.parse(Self.result("err_param"))
    }

    private func reply(to command: LumixCommand) -> String {
        switch (command.mode, command.type, command.value) {
        case ("getinfo", "capability"?, _):
            return "<camrply><result>ok</result><comm_proto_ver>1.3</comm_proto_ver>" +
                "<productinfo><modelname>GM1S-DEMO</modelname></productinfo>" +
                "<camspeclist><camspec>geotag_add_enable</camspec></camspeclist></camrply>"
        case ("camcmd", _, "playmode"?):
            return Self.result("ok")
        case ("startsenddata", "geodata"?, let length?):
            expectedUploadLength = Int(length)
            return "<camrply><result>ok</result><method>once</method></camrply>"
        case ("camctrl", "add_location_data"?, "start"?):
            guard !uploadedRecords.isEmpty else { return Self.result("err_non_support") }
            writeState = "prepare"
            progressPolls = 0
            return Self.result("ok")
        case ("camctrl", "add_location_data"?, "abort"?):
            if writeState == "prepare" || writeState == "exec" { writeState = "error-cancel" }
            return Self.result("ok")
        case ("getprogress", "add_location_data"?, _):
            guard let state = writeState else { return Self.result("err_non_support") }
            if state == "error-cancel" {
                return "<camrply><result>ok</result><state>error</state><progress>40</progress><err>cancel</err></camrply>"
            }
            progressPolls += 1
            writeState = progressPolls >= 3 ? "finish" : "exec"
            let progress = writeState == "finish" ? 100 : progressPolls * 30
            return "<camrply><result>ok</result><state>\(writeState ?? "exec")</state><progress>\(progress)</progress><err></err></camrply>"
        case ("getsetting", "clock"?, _):
            return "<camrply><result>ok</result><settingvalue clock=\"\(clockValue)\"></settingvalue></camrply>"
        default:
            return Self.result("err_param")
        }
    }

    private static func result(_ code: String) -> String {
        "<camrply><result>\(code)</result></camrply>"
    }

    /// Extracts the part body from Image App's single-part framing.
    static func payload(in body: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        let terminator = Data("--\(LumixGeodataUpload.boundary)--".utf8)
        guard let headerEnd = body.range(of: separator),
              body.count >= headerEnd.upperBound + terminator.count,
              body.suffix(terminator.count) == terminator else { return nil }
        return body.subdata(in: headerEnd.upperBound..<(body.count - terminator.count))
    }

    /// A short demo walk ending a few minutes ago, for UI tests and previews.
    static func demoSamples(endingAt end: Date = Date().addingTimeInterval(-5 * 60)) -> [LocationSample] {
        (0..<40).map { index in
            LocationSample(
                timestamp: end.addingTimeInterval(TimeInterval(index - 39) * 30),
                latitude: 35.6595 + Double(index) * 0.0001,
                longitude: 139.7005 + Double(index) * 0.00015,
                altitude: 40,
                horizontalAccuracy: 8
            )
        }
    }
}
