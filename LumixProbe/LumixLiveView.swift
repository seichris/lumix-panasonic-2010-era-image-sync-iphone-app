import CoreGraphics
import Darwin
import Foundation
import ImageIO

// `cam.cgi?mode=startstream&value=<port>` makes the camera send one UDP datagram
// per live-view frame to the requesting phone. Each datagram starts with a
// big-endian header, an optional extension carrying AF frames and the live
// exposure, and then one complete JPEG:
//
//   0   u16  total length          30  u16  extension length E
//   2   s16  version (0x0100)      32  E    extension (s16 type, frames, exposure)
//   9   6    camera MAC            32+E     JPEG (FFD8 … FFD9)
//
// Layout from the GX80 captures and Image App analysis in SahajJain01/lumix-local;
// libgphoto2 and lumix-link-desktop locate the JPEG by its SOI marker instead,
// which is kept as a fallback for older headers.

struct LumixLiveViewFrameMetadata: Equatable, Sendable {
    struct AFFrame: Equatable, Sendable {
        /// Frame corners on the camera's 0…1000 grid.
        let x0: Int
        let y0: Int
        let x1: Int
        let y1: Int
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let kind: UInt8
    }

    struct Exposure: Equatable, Sendable {
        let apertureClosed: Double?
        let apertureOpen: Double?
        let aperture: Double?
        let shutterFastest: Double?
        let shutterSlowest: Double?
        let shutter: Double?
        /// Exposure value relative to the metered value, in thirds of a stop.
        let exposureThirds: Int

        var apertureLabel: String { LumixAPEX.apertureLabel(aperture) }
        var shutterLabel: String { LumixAPEX.shutterLabel(shutter) }
        var exposureLabel: String { LumixAPEX.compensationLabel(thirds: exposureThirds) }
    }

    var extensionType: Int?
    var afFrames: [AFFrame] = []
    var exposure: Exposure?
}

enum LumixLiveViewPacketError: Error, Equatable, Sendable {
    case tooShort(Int)
    case missingJPEG
    case incompleteJPEG
    case undecodableJPEG
}

struct LumixLiveViewPacket: Sendable {
    static let minimumLength = 34
    static let headerLength = 32

    let jpeg: Data
    let metadata: LumixLiveViewFrameMetadata

    static func parse(_ datagram: Data) throws -> LumixLiveViewPacket {
        let bytes = [UInt8](datagram)
        guard bytes.count >= minimumLength else { throw LumixLiveViewPacketError.tooShort(bytes.count) }

        let declaredLength = Int(bytes.readUInt16(at: 0) ?? 0)
        let extensionLength = Int(bytes.readUInt16(at: 30) ?? 0)
        let end = (declaredLength > 0 && declaredLength <= bytes.count) ? declaredLength : bytes.count
        let declaredStart = headerLength + extensionLength

        let jpegStart: Int
        if declaredStart + 1 < end, bytes[declaredStart] == 0xFF, bytes[declaredStart + 1] == 0xD8 {
            jpegStart = declaredStart
        } else if let soi = bytes.firstMarker(0xD8, from: headerLength, before: end) {
            jpegStart = soi
        } else {
            throw LumixLiveViewPacketError.missingJPEG
        }

        guard let jpegEnd = bytes.endOfJPEG(from: jpegStart, before: end) else {
            throw LumixLiveViewPacketError.incompleteJPEG
        }

        var metadata = LumixLiveViewFrameMetadata()
        if extensionLength > 0, declaredStart <= jpegStart {
            metadata = parseExtension(bytes, length: extensionLength)
        }
        return LumixLiveViewPacket(jpeg: Data(bytes[jpegStart..<jpegEnd]), metadata: metadata)
    }

    private static func parseExtension(_ bytes: [UInt8], length: Int) -> LumixLiveViewFrameMetadata {
        var reader = LiveViewByteReader(bytes: bytes, offset: headerLength, limit: min(bytes.count, headerLength + length))
        var metadata = LumixLiveViewFrameMetadata()
        guard let type = reader.int16() else { return metadata }
        metadata.extensionType = Int(type)

        let compactFrames: Set<Int16> = [1, 5, 6, 8, 9]
        let wideFrames: Set<Int16> = [10, 12]
        if compactFrames.contains(type) || wideFrames.contains(type) {
            guard let frames = reader.afFrames(wide: wideFrames.contains(type)) else { return metadata }
            metadata.afFrames = frames
        }
        if [5, 6, 8, 9, 10, 12].contains(type) {
            metadata.exposure = reader.exposure()
        }
        return metadata
    }
}

/// Bounds-checked reader: malformed extensions yield partial metadata, never a crash.
private struct LiveViewByteReader {
    let bytes: [UInt8]
    var offset: Int
    let limit: Int

    mutating func uint8() -> UInt8? {
        guard offset < limit else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func int8() -> Int8? {
        uint8().map { Int8(bitPattern: $0) }
    }

    mutating func int16() -> Int16? {
        guard offset + 1 < limit else { return nil }
        defer { offset += 2 }
        return Int16(bitPattern: UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
    }

    mutating func skip(_ count: Int) -> Bool {
        guard offset + count <= limit else { return false }
        offset += count
        return true
    }

    mutating func afFrames(wide: Bool) -> [LumixLiveViewFrameMetadata.AFFrame]? {
        // Record-set header: s16 sub-type, 11 bytes, u8 count.
        guard int16() != nil, skip(11), let count = uint8() else { return nil }
        var frames: [LumixLiveViewFrameMetadata.AFFrame] = []
        for _ in 0..<Int(count) {
            guard let x0 = int16(), let y0 = int16(), let x1 = int16(), let y1 = int16(),
                  let red = uint8(), let green = uint8(), let blue = uint8(), let kind = uint8() else { return frames }
            if wide, !skip(4) { return frames }
            frames.append(.init(x0: Int(x0), y0: Int(y0), x1: Int(x1), y1: Int(y1),
                                red: red, green: green, blue: blue, kind: kind))
        }
        return frames
    }

    mutating func exposure() -> LumixLiveViewFrameMetadata.Exposure? {
        var values: [Int16] = []
        for _ in 0..<18 {
            guard let value = int16() else { return nil }
            values.append(value)
        }
        guard let thirds = int8() else { return nil }
        func apex(_ index: Int) -> Double? {
            values[index + 1] == 0 ? nil : Double(values[index]) / Double(values[index + 1])
        }
        return .init(apertureClosed: apex(0), apertureOpen: apex(2), aperture: apex(4),
                     shutterFastest: apex(6), shutterSlowest: apex(8), shutter: apex(10),
                     exposureThirds: Int(thirds))
    }
}

private extension Array where Element == UInt8 {
    func readUInt16(at offset: Int) -> UInt16? {
        guard offset + 1 < count else { return nil }
        return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func firstMarker(_ marker: UInt8, from start: Int, before end: Int) -> Int? {
        var index = start
        while index + 1 < end {
            if self[index] == 0xFF, self[index + 1] == marker { return index }
            index += 1
        }
        return nil
    }

    /// The offset just past the JPEG's EOI marker. Trailing padding is ignored;
    /// a frame without an EOI is incomplete.
    func endOfJPEG(from start: Int, before end: Int) -> Int? {
        var index = end - 2
        while index > start {
            if self[index] == 0xFF, self[index + 1] == 0xD9 { return index + 2 }
            index -= 1
        }
        return nil
    }
}

// MARK: - Decoded frames

struct LumixLiveViewFrame: @unchecked Sendable {
    let image: CGImage
    let metadata: LumixLiveViewFrameMetadata
    let receivedAt: Date
}

enum LumixLiveViewEvent: @unchecked Sendable {
    case frame(LumixLiveViewFrame)
    case malformed(LumixLiveViewPacketError)
}

enum LumixLiveViewDecoder {
    static func decode(_ datagram: Data, receivedAt: Date = Date()) -> LumixLiveViewEvent {
        do {
            let packet = try LumixLiveViewPacket.parse(datagram)
            guard let image = decodeJPEG(packet.jpeg) else { return .malformed(.undecodableJPEG) }
            return .frame(LumixLiveViewFrame(image: image, metadata: packet.metadata, receivedAt: receivedAt))
        } catch let error as LumixLiveViewPacketError {
            return .malformed(error)
        } catch {
            return .malformed(.missingJPEG)
        }
    }

    static func decodeJPEG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// Produces live-view frames for the remote shooting session.
protocol LumixLiveViewSource: AnyObject, Sendable {
    /// Starts receiving and returns the local UDP port the camera should stream to.
    func start(handler: @escaping @Sendable (LumixLiveViewEvent) -> Void) throws -> UInt16
    func stop()
}

enum LumixLiveViewReceiverError: LocalizedError, Equatable {
    case socket(String, Int32)
    case noFreePort

    var errorDescription: String? {
        switch self {
        case let .socket(operation, code):
            return "Live view \(operation) failed: \(String(cString: strerror(code))) (\(code))."
        case .noFreePort:
            return "No local UDP port was free for the live view."
        }
    }
}

/// Receives the camera's UDP live-view stream on a non-blocking socket.
///
/// Datagrams from any address other than the camera are dropped, so another
/// device on the camera's network cannot inject frames into the viewfinder.
final class LumixLiveViewReceiver: LumixLiveViewSource, @unchecked Sendable {
    static let defaultPorts: [UInt16] = [49199] + Array(49200...49210)

    private let cameraAddress: in_addr?
    private let candidatePorts: [UInt16]
    private let queue = DispatchQueue(label: "com.web3.gm1sync.live-view", qos: .userInteractive)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var handler: (@Sendable (LumixLiveViewEvent) -> Void)?
    private var buffer = [UInt8](repeating: 0, count: 65_536)
    private var foreignDatagrams = 0

    init(cameraHost: String, candidatePorts: [UInt16] = LumixLiveViewReceiver.defaultPorts) {
        var address = in_addr()
        cameraAddress = inet_pton(AF_INET, cameraHost, &address) == 1 ? address : nil
        self.candidatePorts = candidatePorts
    }

    deinit { stop() }

    var droppedForeignDatagrams: Int { lock.withLock { foreignDatagrams } }

    func start(handler: @escaping @Sendable (LumixLiveViewEvent) -> Void) throws -> UInt16 {
        stop()
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw LumixLiveViewReceiverError.socket("socket", errno) }
        var shouldClose = true
        defer { if shouldClose { Darwin.close(descriptor) } }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var receiveBuffer: Int32 = 2 * 1024 * 1024
        setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        var boundPort: UInt16?
        for port in candidatePorts + [0] where Self.bind(descriptor, port: port) {
            boundPort = Self.localPort(of: descriptor) ?? port
            break
        }
        guard let boundPort, boundPort != 0 else { throw LumixLiveViewReceiverError.noFreePort }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LumixLiveViewReceiverError.socket("fcntl", errno)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(descriptor) }
        source.setCancelHandler { Darwin.close(descriptor) }
        lock.withLock {
            self.handler = handler
            self.source = source
        }
        shouldClose = false
        source.resume()
        return boundPort
    }

    func stop() {
        let source: DispatchSourceRead? = lock.withLock {
            let current = self.source
            self.source = nil
            handler = nil
            return current
        }
        source?.cancel()
    }

    private func drain(_ descriptor: Int32) {
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, rawBuffer.baseAddress, rawBuffer.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            guard let handler = lock.withLock({ self.handler }) else { return }
            if let cameraAddress, address.sin_addr.s_addr != cameraAddress.s_addr {
                lock.withLock { foreignDatagrams += 1 }
                continue
            }
            handler(LumixLiveViewDecoder.decode(Data(buffer[0..<count])))
        }
    }

    private static func bind(_ descriptor: Int32, port: UInt16) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func localPort(of descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
