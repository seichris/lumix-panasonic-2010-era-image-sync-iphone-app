import Darwin
import Foundation
import Network

enum PushTransferNetwork {
    struct LocalAddress: Equatable, Sendable {
        let address: String
        let interface: String
    }

    /// The phone's IPv4 address on the camera's subnet, used in the advertised URLs.
    static func localAddress(towards cameraHost: String) -> LocalAddress? {
        var camera = in_addr()
        guard inet_pton(AF_INET, cameraHost, &camera) == 1 else { return nil }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard local.s_addr & netmask.s_addr == camera.s_addr & netmask.s_addr else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var copy = local
            guard inet_ntop(AF_INET, &copy, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            return LocalAddress(address: String(cString: text), interface: String(cString: entry.ifa_name))
        }
        return nil
    }
}

enum PushTransferServerError: LocalizedError {
    case noPort

    var errorDescription: String? {
        "Retro LUMIX Sync could not open a local port to receive photos."
    }
}

/// Accepts the camera's HTTP connections and hands their bytes to the router.
/// Connections from any address other than the camera's are refused.
final class PushTransferHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.web3.gm1sync.push-http")
    private let allowedPeer: IPv4Address?
    private let router: PushHTTPRouting
    private let idleTimeout: TimeInterval
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: (connection: NWConnection, processor: PushHTTPConnectionProcessor)] = [:]
    private var idleTimers: [ObjectIdentifier: DispatchWorkItem] = [:]

    /// - Parameter allowedPeerHost: The camera's IPv4 address; `nil` accepts any peer (tests only).
    init(allowedPeerHost: String?, router: PushHTTPRouting, idleTimeout: TimeInterval = 30) {
        allowedPeer = allowedPeerHost.flatMap(IPv4Address.init)
        self.router = router
        self.idleTimeout = idleTimeout
    }

    /// Starts listening, preferring the given ports so the camera's cached URLs stay valid.
    func start(preferredPorts: [UInt16]) async throws -> UInt16 {
        for port in preferredPorts + [0] {
            if let bound = try? await startListener(port: port) { return bound }
        }
        throw PushTransferServerError.noPort
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for id in Array(connections.keys) { closeConnection(id, abortUpload: true) }
        }
    }

    private func startListener(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: endpointPort)
        let gate = ListenerStartGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    gate.resume(.success(listener?.port?.rawValue ?? port))
                case let .failed(error):
                    gate.resume(.failure(error))
                    listener?.cancel()
                case .cancelled:
                    gate.resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            queue.sync {
                self.listener?.cancel()
                self.listener = listener
            }
            listener.start(queue: queue)
        }
    }

    // Everything below runs on `queue`.

    private func accept(_ connection: NWConnection) {
        if let allowedPeer {
            guard case let .hostPort(host, _) = connection.endpoint, Self.ipv4(of: host) == allowedPeer else {
                connection.cancel()
                return
            }
        }
        let id = ObjectIdentifier(connection)
        connections[id] = (connection, PushHTTPConnectionProcessor(router: router))
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.closeConnection(id, abortUpload: true)
            default:
                break
            }
        }
        connection.start(queue: queue)
        resetIdleTimer(id)
        receive(id)
    }

    private func receive(_ id: ObjectIdentifier) {
        guard let entry = connections[id] else { return }
        entry.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self, let entry = self.connections[id] else { return }
            self.resetIdleTimer(id)
            if let data, !data.isEmpty {
                let outputs = entry.processor.receive(data)
                if self.deliver(outputs, id: id) { return }
            }
            if isComplete || error != nil {
                self.closeConnection(id, abortUpload: true)
                return
            }
            self.receive(id)
        }
    }

    /// Sends the processor's output; returns true when the connection was closed.
    private func deliver(_ outputs: [PushHTTPOutput], id: ObjectIdentifier) -> Bool {
        guard let entry = connections[id] else { return true }
        var shouldClose = false
        for output in outputs {
            switch output {
            case let .send(data):
                entry.connection.send(content: data, completion: .contentProcessed { _ in })
            case .close:
                shouldClose = true
            }
        }
        guard shouldClose else { return false }
        let connection = entry.connection
        connections.removeValue(forKey: id)
        idleTimers.removeValue(forKey: id)?.cancel()
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
        return true
    }

    private func closeConnection(_ id: ObjectIdentifier, abortUpload: Bool) {
        idleTimers.removeValue(forKey: id)?.cancel()
        guard let entry = connections.removeValue(forKey: id) else { return }
        if abortUpload { entry.processor.connectionClosed() }
        entry.connection.cancel()
    }

    /// The IPv4 address of a peer, including one a dual-stack listener reports as IPv4-mapped IPv6.
    static func ipv4(of host: NWEndpoint.Host) -> IPv4Address? {
        switch host {
        case let .ipv4(address):
            return address
        case let .ipv6(address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else {
                return nil
            }
            return IPv4Address(Data(bytes[12..<16]))
        default:
            return nil
        }
    }

    private func resetIdleTimer(_ id: ObjectIdentifier) {
        idleTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeConnection(id, abortUpload: true) }
        idleTimers[id] = work
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }
}

private final class ListenerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    func install(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<UInt16, Error>) {
        let continuation: CheckedContinuation<UInt16, Error>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// Whether the system lets this app use IP multicast.
enum SSDPMulticastStatus: Equatable, Sendable {
    case unknown
    case available
    /// iOS requires the `com.apple.developer.networking.multicast` entitlement.
    case blocked(String)
}

enum SSDPAnnouncerEvent: Sendable {
    case cameraResponded(SSDPMessage)
    case cameraSearched(SSDPMessage)
    case multicastStatus(SSDPMulticastStatus)
}

/// Advertises the receiver over SSDP.
///
/// NOTIFY and M-SEARCH datagrams go straight to the camera's SSDP port as
/// unicast, which needs no entitlement. Multicast announcements and answers to
/// the camera's own multicast searches are attempted as well; without Apple's
/// multicast entitlement iOS rejects them, and the status says so.
final class SSDPAnnouncer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.web3.gm1sync.ssdp")
    private let cameraHost: String
    private let localAddress: String?
    private let advertisement: SSDPAdvertisement
    private let emit: @Sendable (SSDPAnnouncerEvent) -> Void
    private var interval: TimeInterval
    private var unicastSocket: Int32 = -1
    private var unicastSource: DispatchSourceRead?
    private var multicastSocket: Int32 = -1
    private var multicastSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var multicastStatus: SSDPMulticastStatus = .unknown
    private let ssdpPort: UInt16

    init(
        cameraHost: String,
        localAddress: String?,
        advertisement: SSDPAdvertisement,
        interval: TimeInterval = 3,
        ssdpPort: UInt16 = PushTransferProtocol.ssdpPort,
        emit: @escaping @Sendable (SSDPAnnouncerEvent) -> Void
    ) {
        self.cameraHost = cameraHost
        self.localAddress = localAddress
        self.advertisement = advertisement
        self.interval = interval
        self.ssdpPort = ssdpPort
        self.emit = emit
    }

    deinit {
        let unicast = unicastSource, multicast = multicastSource, timer = self.timer
        unicast?.cancel()
        multicast?.cancel()
        timer?.cancel()
    }

    func start() throws {
        try queue.sync {
            let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { throw LumixLiveViewReceiverError.socket("socket", errno) }
            guard Self.bind(descriptor, port: 0), Self.makeNonBlocking(descriptor) else {
                let code = errno
                Darwin.close(descriptor)
                throw LumixLiveViewReceiverError.socket("bind", code)
            }
            if let localAddress { Self.setMulticastInterface(descriptor, address: localAddress) }
            unicastSocket = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(descriptor, isMulticastListener: false) }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            unicastSource = source
            openMulticastListener()
            scheduleTimer()
        }
    }

    /// Sends a burst of announcements now, for example after the app returns to the foreground.
    func announceNow() {
        queue.async { self.announce() }
    }

    func setInterval(_ seconds: TimeInterval) {
        queue.async {
            guard self.interval != seconds else { return }
            self.interval = seconds
            if self.timer != nil { self.scheduleTimer() }
        }
    }

    func stop(sayGoodbye: Bool) {
        queue.sync {
            if sayGoodbye, unicastSocket >= 0 {
                for datagram in advertisement.notifications(alive: false) { send(datagram) }
            }
            timer?.cancel()
            timer = nil
            unicastSource?.cancel()
            unicastSource = nil
            multicastSource?.cancel()
            multicastSource = nil
            unicastSocket = -1
            multicastSocket = -1
        }
    }

    // Everything below runs on `queue`.

    private func scheduleTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.announce() }
        timer.resume()
        self.timer = timer
    }

    private func announce() {
        guard unicastSocket >= 0 else { return }
        for datagram in advertisement.notifications(alive: true) { send(datagram) }
        sendTo(cameraHost, port: ssdpPort, data: SSDPAdvertisement.cameraSearch())
    }

    private func send(_ datagram: Data) {
        sendTo(cameraHost, port: ssdpPort, data: datagram)
        if case .blocked = multicastStatus { return }
        let result = sendTo(PushTransferProtocol.ssdpMulticastAddress, port: PushTransferProtocol.ssdpPort, data: datagram)
        if result == 0 {
            update(.available)
        } else {
            update(.blocked("iOS refused multicast (\(String(cString: strerror(result))))."))
        }
    }

    /// Returns 0 on success or the `errno` of the failure.
    @discardableResult
    private func sendTo(_ host: String, port: UInt16, data: Data) -> Int32 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return EINVAL }
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(unicastSocket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    private func update(_ status: SSDPMulticastStatus) {
        guard status != multicastStatus else { return }
        multicastStatus = status
        emit(.multicastStatus(status))
    }

    private func openMulticastListener() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var membership = ip_mreq()
        inet_pton(AF_INET, PushTransferProtocol.ssdpMulticastAddress, &membership.imr_multiaddr)
        if let localAddress { inet_pton(AF_INET, localAddress, &membership.imr_interface) }
        guard Self.bind(descriptor, port: ssdpPort), Self.makeNonBlocking(descriptor),
              setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
            Darwin.close(descriptor)
            return
        }
        multicastSocket = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(descriptor, isMulticastListener: true) }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        multicastSource = source
    }

    private func drain(_ descriptor: Int32, isMulticastListener: Bool) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var camera = in_addr()
        let hasCameraAddress = inet_pton(AF_INET, cameraHost, &camera) == 1
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            // Only the camera's datagrams matter; ignore every other device on the network.
            guard hasCameraAddress, address.sin_addr.s_addr == camera.s_addr,
                  let message = SSDPMessage.parse(Data(buffer[0..<count])) else { continue }
            if message.isSearchResponse {
                emit(.cameraResponded(message))
            } else if message.isSearch, isMulticastListener {
                emit(.cameraSearched(message))
                if let target = message.header("ST"), let reply = advertisement.searchResponse(for: target) {
                    let port = UInt16(bigEndian: address.sin_port)
                    sendTo(cameraHost, port: port, data: reply)
                }
            }
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

    private static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL, 0)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func setMulticastInterface(_ descriptor: Int32, address: String) {
        var interface = in_addr()
        guard inet_pton(AF_INET, address, &interface) == 1 else { return }
        setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, &interface, socklen_t(MemoryLayout<in_addr>.size))
    }
}
