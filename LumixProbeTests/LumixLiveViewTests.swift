import Darwin
import Foundation
import XCTest
@testable import GM1Sync

final class LumixLiveViewTests: XCTestCase {
    private var jpeg: Data!

    override func setUpWithError() throws {
        jpeg = try XCTUnwrap(LumixLiveViewPacketBuilder.syntheticJPEG(width: 64, height: 48))
    }

    func testParsesHeaderAFFramesAndLiveExposure() throws {
        let frame = LumixLiveViewFrameMetadata.AFFrame(x0: 400, y0: 380, x1: 600, y1: 620, red: 0, green: 255, blue: 0, kind: 1)
        let exposure = LumixLiveViewPacketBuilder.Exposure(
            apertureClosed: 9, apertureOpen: 3, aperture: 1094.0 / 256, shutterFastest: 14,
            shutterSlowest: -6, shutter: 6, exposureThirds: -3
        )
        let datagram = LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: 5, frames: [frame], exposure: exposure)
        let packet = try LumixLiveViewPacket.parse(datagram)

        XCTAssertEqual(packet.jpeg, jpeg)
        XCTAssertEqual(packet.metadata.extensionType, 5)
        XCTAssertEqual(packet.metadata.afFrames, [frame])
        let parsedExposure = try XCTUnwrap(packet.metadata.exposure)
        XCTAssertEqual(parsedExposure.apertureLabel, "f/4.4")
        XCTAssertEqual(parsedExposure.shutterLabel, "1/60")
        XCTAssertEqual(parsedExposure.exposureLabel, "−1")
        XCTAssertEqual(parsedExposure.apertureOpen, 3)
    }

    func testParsesWideAFFrameRecords() throws {
        let frames = [
            LumixLiveViewFrameMetadata.AFFrame(x0: 0, y0: 0, x1: 100, y1: 100, red: 255, green: 255, blue: 255, kind: 2),
            LumixLiveViewFrameMetadata.AFFrame(x0: 900, y0: 900, x1: 1000, y1: 1000, red: 0, green: 200, blue: 0, kind: 3)
        ]
        let packet = try LumixLiveViewPacket.parse(
            LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: 10, frames: frames)
        )
        XCTAssertEqual(packet.metadata.afFrames, frames)
        XCTAssertNotNil(packet.metadata.exposure)
        XCTAssertEqual(packet.jpeg, jpeg)
    }

    func testFallsBackToTheJPEGMarkerWhenTheExtensionLengthIsWrong() throws {
        var datagram = LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: 5)
        datagram[30] = 0x7F
        datagram[31] = 0xFF
        let packet = try LumixLiveViewPacket.parse(datagram)
        XCTAssertEqual(packet.jpeg, jpeg)
        XCTAssertTrue(packet.metadata.afFrames.isEmpty, "An implausible extension is not parsed")
    }

    func testIgnoresTrailingPaddingAndAnOversizedDeclaredLength() throws {
        var padded = LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: nil, trailingPadding: 33)
        XCTAssertEqual(try LumixLiveViewPacket.parse(padded).jpeg, jpeg)
        padded[0] = 0xFF
        padded[1] = 0xFF
        XCTAssertEqual(try LumixLiveViewPacket.parse(padded).jpeg, jpeg)
    }

    func testRejectsShortMissingAndIncompleteFrames() {
        XCTAssertThrowsError(try LumixLiveViewPacket.parse(Data(count: 20))) { error in
            XCTAssertEqual(error as? LumixLiveViewPacketError, .tooShort(20))
        }
        XCTAssertThrowsError(try LumixLiveViewPacket.parse(Data(repeating: 0x11, count: 400))) { error in
            XCTAssertEqual(error as? LumixLiveViewPacketError, .missingJPEG)
        }
        let full = LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: 5)
        let truncated = full.prefix(full.count - 40)
        XCTAssertThrowsError(try LumixLiveViewPacket.parse(Data(truncated))) { error in
            XCTAssertEqual(error as? LumixLiveViewPacketError, .incompleteJPEG)
        }
    }

    func testTruncatedExtensionYieldsPartialMetadataWithoutCrashing() throws {
        // Extension type 5 promises frames and an exposure block but carries only part of a frame.
        var extensionBytes = Data([0x00, 0x05, 0x00, 0x00])
        extensionBytes.append(Data(count: 11))
        extensionBytes.append(contentsOf: [0x03, 0x01, 0x90])
        var header = Data(count: 32)
        header[2] = 0x01
        header[30] = UInt8(extensionBytes.count >> 8)
        header[31] = UInt8(extensionBytes.count & 0xFF)
        let packet = try LumixLiveViewPacket.parse(header + extensionBytes + jpeg)
        XCTAssertEqual(packet.metadata.extensionType, 5)
        XCTAssertTrue(packet.metadata.afFrames.isEmpty)
        XCTAssertNil(packet.metadata.exposure)
        XCTAssertEqual(packet.jpeg, jpeg)
    }

    func testDecoderReportsFramesAndUndecodableJPEGs() {
        guard case let .frame(frame) = LumixLiveViewDecoder.decode(LumixLiveViewPacketBuilder.datagram(jpeg: jpeg)) else {
            return XCTFail("A valid datagram must decode")
        }
        XCTAssertEqual(frame.image.width, 64)
        XCTAssertEqual(frame.image.height, 48)

        let garbage = Data([0xFF, 0xD8]) + Data(repeating: 0x42, count: 200) + Data([0xFF, 0xD9])
        guard case .malformed(.undecodableJPEG) = LumixLiveViewDecoder.decode(LumixLiveViewPacketBuilder.datagram(jpeg: garbage, extensionType: nil)) else {
            return XCTFail("A JPEG-shaped payload that cannot be decoded is reported as malformed")
        }
    }

    func testRandomDatagramsNeverCrashTheParser() {
        var generator = SystemRandomNumberGenerator()
        for length in stride(from: 0, through: 2_000, by: 37) {
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if length > 40 {
                bytes[30] = UInt8.random(in: 0...1, using: &generator)
                bytes[32] = 0
                bytes[33] = [1, 5, 10, 12].randomElement(using: &generator)!
            }
            _ = try? LumixLiveViewPacket.parse(Data(bytes))
        }
    }

    func testReceiverDeliversCameraDatagramsAndStopsCleanly() throws {
        try skipWhereReceivingIsSandboxed()
        let receiver = LumixLiveViewReceiver(cameraHost: "127.0.0.1", candidatePorts: Array(52_100...52_140))
        let events = EventCollector()
        let port = try receiver.start { events.append($0) }
        XCTAssertGreaterThan(port, 0)

        try sendDatagram(LumixLiveViewPacketBuilder.datagram(jpeg: jpeg), to: port)
        try sendDatagram(Data(repeating: 0x42, count: 120), to: port)
        try waitUntil { events.frames == 1 && events.malformed == 1 }

        receiver.stop()
        try sendDatagram(LumixLiveViewPacketBuilder.datagram(jpeg: jpeg), to: port)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(events.frames, 1, "Nothing is delivered after stop()")
    }

    func testReceiverDropsDatagramsFromOtherHosts() throws {
        try skipWhereReceivingIsSandboxed()
        let receiver = LumixLiveViewReceiver(cameraHost: "127.0.0.2", candidatePorts: Array(52_150...52_190))
        let events = EventCollector()
        let port = try receiver.start { events.append($0) }
        defer { receiver.stop() }

        try sendDatagram(LumixLiveViewPacketBuilder.datagram(jpeg: jpeg), to: port)
        try waitUntil { receiver.droppedForeignDatagrams == 1 }
        XCTAssertEqual(events.frames, 0)
    }

    // MARK: Helpers

    /// Remote shooting is iPhone-only. The sandboxed Mac app has no network-server
    /// entitlement, so its hosted tests cannot bind a UDP port.
    private func skipWhereReceivingIsSandboxed() throws {
        #if os(macOS)
        throw XCTSkip("The sandboxed Mac test host cannot bind UDP ports; live view is iPhone-only.")
        #endif
    }

    private func sendDatagram(_ data: Data, to port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        XCTAssertEqual(sent, data.count)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out waiting for live-view events") }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frameCount = 0
    private var malformedCount = 0

    var frames: Int { lock.withLock { frameCount } }
    var malformed: Int { lock.withLock { malformedCount } }

    func append(_ event: LumixLiveViewEvent) {
        lock.withLock {
            switch event {
            case .frame: frameCount += 1
            case .malformed: malformedCount += 1
            }
        }
    }
}
