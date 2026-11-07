import CryptoKit
import Foundation

// A deliberately small HTTP/1.1 server core for the camera's uploads. It is
// independent of sockets so every framing rule can be tested with byte fixtures.

struct PushHTTPRequestHead: Equatable, Sendable {
    let method: String
    let target: String
    let version: String
    /// Header names are lowercased.
    let headers: [String: String]

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var contentLength: Int64? { header("content-length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } }
    var isChunked: Bool { header("transfer-encoding")?.lowercased().contains("chunked") == true }
    var expectsContinue: Bool { header("expect")?.lowercased() == "100-continue" }

    static func parse(_ data: Data) -> PushHTTPRequestHead? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].uppercased().hasPrefix("HTTP/1."), !parts[0].isEmpty else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        return PushHTTPRequestHead(method: parts[0].uppercased(), target: parts[1], version: parts[2], headers: headers)
    }
}

struct PushHTTPResponse: Equatable, Sendable {
    let status: Int
    let reason: String
    let contentType: String?
    let body: Data
    var extraHeaders: [(String, String)] = []

    static func == (lhs: PushHTTPResponse, rhs: PushHTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.reason == rhs.reason && lhs.contentType == rhs.contentType && lhs.body == rhs.body
    }

    static func xml(_ text: String, status: Int = 200, reason: String = "OK") -> PushHTTPResponse {
        PushHTTPResponse(status: status, reason: reason, contentType: "text/xml; charset=\"utf-8\"", body: Data(text.utf8),
                         extraHeaders: [("EXT", "")])
    }

    static func empty(_ status: Int, _ reason: String) -> PushHTTPResponse {
        PushHTTPResponse(status: status, reason: reason, contentType: nil, body: Data())
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in extraHeaders { head += value.isEmpty ? "\(name):\r\n" : "\(name): \(value)\r\n" }
        head += "Server: \(PushTransferProtocol.serverHeader)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Sent before the upload body. Shutterlink sends it for every upload, whether or not
    /// the camera asked with `Expect: 100-continue`; HTTP/1.1 clients must accept it either way.
    static let continueInterim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
}

enum PushHTTPOutput: Equatable, Sendable {
    case send(Data)
    case close
}

enum PushUploadFailure: Error, Equatable, Sendable {
    case connectionClosed(receivedBytes: Int64)
    case malformedFraming
    case tooLarge(limit: Int64)
    case incompleteJPEG(receivedBytes: Int64)
    case sizeMismatch(declared: Int64, received: Int64)
    case storage(String)
    case cancelled

    var message: String {
        switch self {
        case let .connectionClosed(bytes):
            return "The camera stopped sending after \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
        case .malformedFraming: return "The camera sent an unreadable upload."
        case let .tooLarge(limit):
            return "The upload exceeded \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file))."
        case let .incompleteJPEG(bytes):
            return "The received file (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) is not a complete JPEG."
        case let .sizeMismatch(declared, received):
            return "The camera announced \(declared) bytes but sent \(received)."
        case let .storage(message): return "The file could not be stored: \(message)"
        case .cancelled: return "Receiving was stopped."
        }
    }
}

/// Receives one request body.
protocol PushUploadSink: AnyObject {
    func append(_ data: Data) throws
    /// The complete body arrived; returns the HTTP response for the camera.
    func finish() -> PushHTTPResponse
    func abort(_ failure: PushUploadFailure)
}

enum PushHTTPRoute {
    case respond(PushHTTPResponse)
    /// Collects a small body (SOAP) and answers once it is complete.
    case collect(limit: Int, respond: (Data) -> PushHTTPResponse)
    /// Streams a large body (an upload) to a sink, after an interim `100 Continue`.
    case stream(PushUploadSink)
}

protocol PushHTTPRouting: AnyObject {
    func route(_ head: PushHTTPRequestHead) -> PushHTTPRoute
}

/// Decodes `Transfer-Encoding: chunked`.
struct PushChunkedDecoder {
    private enum State: Equatable {
        case size
        case data(remaining: Int)
        case dataTerminator
        case trailer
        case done
    }

    private var state: State = .size
    var isFinished: Bool { state == .done }

    /// Consumes as much of `input` as possible and returns the decoded payload.
    mutating func decode(_ input: inout Data) throws -> Data {
        var payload = Data()
        while !input.isEmpty, state != .done {
            switch state {
            case .size:
                guard let lineEnd = input.range(of: Data("\r\n".utf8)) else {
                    if input.count > 1_024 { throw PushUploadFailure.malformedFraming }
                    return payload
                }
                let line = String(decoding: input[input.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                input.removeSubrange(input.startIndex..<lineEnd.upperBound)
                let sizeText = line.split(separator: ";", maxSplits: 1).first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? ""
                guard let size = Int(sizeText, radix: 16), size >= 0 else { throw PushUploadFailure.malformedFraming }
                state = size == 0 ? .trailer : .data(remaining: size)
            case let .data(remaining):
                let count = min(remaining, input.count)
                payload.append(input.prefix(count))
                input.removeFirst(count)
                state = remaining - count == 0 ? .dataTerminator : .data(remaining: remaining - count)
            case .dataTerminator:
                guard input.count >= 2 else { return payload }
                guard input.prefix(2) == Data("\r\n".utf8) else { throw PushUploadFailure.malformedFraming }
                input.removeFirst(2)
                state = .size
            case .trailer:
                guard let lineEnd = input.range(of: Data("\r\n".utf8)) else {
                    if input.count > 8_192 { throw PushUploadFailure.malformedFraming }
                    return payload
                }
                let isEmptyLine = lineEnd.lowerBound == input.startIndex
                input.removeSubrange(input.startIndex..<lineEnd.upperBound)
                if isEmptyLine { state = .done }
            case .done:
                return payload
            }
        }
        return payload
    }
}

/// Parses one request on one connection and produces the bytes to send back.
/// Every response closes the connection, as the camera's DLNA client expects.
final class PushHTTPConnectionProcessor {
    static let maximumHeadBytes = 16 * 1_024

    private enum Framing {
        case none
        case length(Int64)
        case chunked(PushChunkedDecoder)
    }

    private enum Consumer {
        case discard(PushHTTPResponse)
        case collect(limit: Int, data: Data, respond: (Data) -> PushHTTPResponse)
        case stream(PushUploadSink)
    }

    private enum State {
        case head
        case body(Framing, Consumer)
        case finished
    }

    private let router: PushHTTPRouting
    private var state: State = .head
    private var buffer = Data()

    init(router: PushHTTPRouting) {
        self.router = router
    }

    var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    func receive(_ data: Data) -> [PushHTTPOutput] {
        buffer.append(data)
        var outputs: [PushHTTPOutput] = []
        while true {
            switch state {
            case .finished:
                return outputs
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.maximumHeadBytes {
                        return outputs + finish(with: .empty(431, "Request Header Fields Too Large"))
                    }
                    return outputs
                }
                let headData = buffer[buffer.startIndex..<end.lowerBound]
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                guard let head = PushHTTPRequestHead.parse(Data(headData)) else {
                    return outputs + finish(with: .empty(400, "Bad Request"))
                }
                let framing: Framing
                if head.isChunked {
                    framing = .chunked(PushChunkedDecoder())
                } else if let length = head.contentLength {
                    guard length >= 0 else { return outputs + finish(with: .empty(400, "Bad Request")) }
                    framing = length == 0 ? .none : .length(length)
                } else {
                    framing = .none
                }
                switch router.route(head) {
                case let .respond(response):
                    state = .body(framing, .discard(response))
                case let .collect(limit, respond):
                    state = .body(framing, .collect(limit: limit, data: Data(), respond: respond))
                case let .stream(sink):
                    outputs.append(.send(PushHTTPResponse.continueInterim))
                    state = .body(framing, .stream(sink))
                }
            case let .body(framing, consumer):
                var framing = framing
                var consumer = consumer
                let complete: Bool
                do {
                    let chunk: Data
                    switch framing {
                    case .none:
                        chunk = Data()
                        complete = true
                    case let .length(remaining):
                        let count = Int(min(remaining, Int64(buffer.count)))
                        chunk = buffer.prefix(count)
                        buffer.removeFirst(count)
                        framing = .length(remaining - Int64(count))
                        complete = remaining - Int64(count) == 0
                    case var .chunked(decoder):
                        chunk = try decoder.decode(&buffer)
                        complete = decoder.isFinished
                        framing = .chunked(decoder)
                    }
                    if !chunk.isEmpty {
                        switch consumer {
                        case .discard:
                            break
                        case let .collect(limit, data, respond):
                            guard data.count + chunk.count <= limit else {
                                return outputs + finish(with: .empty(413, "Payload Too Large"))
                            }
                            consumer = .collect(limit: limit, data: data + chunk, respond: respond)
                        case let .stream(sink):
                            try sink.append(chunk)
                        }
                    }
                } catch {
                    let failure = error as? PushUploadFailure ?? .malformedFraming
                    if case let .stream(sink) = consumer { sink.abort(failure) }
                    switch failure {
                    case .malformedFraming:
                        return outputs + finish(with: .empty(400, "Bad Request"))
                    case .tooLarge:
                        return outputs + finish(with: .empty(413, "Payload Too Large"))
                    default:
                        return outputs + finish(with: .empty(500, "Upload Failed"))
                    }
                }
                guard complete else {
                    state = .body(framing, consumer)
                    return outputs
                }
                let response: PushHTTPResponse
                switch consumer {
                case let .discard(value): response = value
                case let .collect(_, data, respond): response = respond(data)
                case let .stream(sink): response = sink.finish()
                }
                return outputs + finish(with: response)
            }
        }
    }

    /// The camera closed the connection; an unfinished upload is discarded.
    func connectionClosed() {
        if case let .body(_, .stream(sink)) = state {
            sink.abort(.connectionClosed(receivedBytes: (sink as? PushUploadFileSink)?.receivedBytes ?? 0))
        }
        state = .finished
    }

    private func finish(with response: PushHTTPResponse) -> [PushHTTPOutput] {
        state = .finished
        buffer.removeAll()
        return [.send(response.serialized()), .close]
    }
}

// MARK: - Received files

struct PushReceivedFile: Equatable, Sendable {
    let token: String
    let filename: String
    let fileURL: URL
    let byteCount: Int64
    let sha256: String
    let receivedAt: Date
}

/// Streams one upload to a temporary file while hashing it and checking that it
/// ends with a complete JPEG. The file is only handed over once it is complete.
final class PushUploadFileSink: PushUploadSink {
    private let token: String
    private let filename: String
    private let declaredSize: Int64?
    private let maximumBytes: Int64
    private let fileURL: URL
    private let onComplete: (PushReceivedFile) -> Void
    private let onFailure: (PushUploadFailure) -> Void
    private let onProgress: (Int64) -> Void
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var detector = JPEGCompletionDetector()
    private var jpegComplete = false
    private var isClosed = false
    private(set) var receivedBytes: Int64 = 0

    init(
        token: String,
        filename: String,
        declaredSize: Int64?,
        directory: URL,
        maximumBytes: Int64,
        onProgress: @escaping (Int64) -> Void,
        onComplete: @escaping (PushReceivedFile) -> Void,
        onFailure: @escaping (PushUploadFailure) -> Void
    ) throws {
        self.token = token
        self.filename = filename
        self.declaredSize = declaredSize
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onFailure = onFailure
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw PushUploadFailure.storage("could not create \(filename)")
        }
        handle = try FileHandle(forWritingTo: fileURL)
    }

    func append(_ data: Data) throws {
        guard !isClosed, let handle else { throw PushUploadFailure.cancelled }
        guard receivedBytes + Int64(data.count) <= maximumBytes else { throw PushUploadFailure.tooLarge(limit: maximumBytes) }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw PushUploadFailure.storage(error.localizedDescription)
        }
        hasher.update(data: data)
        if !jpegComplete {
            for byte in data {
                if detector.consume(byte) {
                    jpegComplete = true
                    break
                }
            }
        }
        receivedBytes += Int64(data.count)
        onProgress(receivedBytes)
    }

    func finish() -> PushHTTPResponse {
        guard !isClosed else { return .empty(500, "Upload Failed") }
        isClosed = true
        try? handle?.close()
        handle = nil
        if let declaredSize, declaredSize > 0, declaredSize != receivedBytes {
            discard(.sizeMismatch(declared: declaredSize, received: receivedBytes))
            return .empty(400, "Incomplete Upload")
        }
        guard receivedBytes > 0, jpegComplete else {
            discard(.incompleteJPEG(receivedBytes: receivedBytes))
            return .empty(400, "Incomplete Upload")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        onComplete(PushReceivedFile(token: token, filename: filename, fileURL: fileURL, byteCount: receivedBytes,
                                    sha256: digest, receivedAt: Date()))
        return .empty(200, "OK")
    }

    func abort(_ failure: PushUploadFailure) {
        guard !isClosed else { return }
        isClosed = true
        try? handle?.close()
        handle = nil
        discard(failure)
    }

    private func discard(_ failure: PushUploadFailure) {
        try? FileManager.default.removeItem(at: fileURL)
        onFailure(failure)
    }
}

extension PushReceivedFile {
    /// SHA-256 of a file on disk, read in blocks.
    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
