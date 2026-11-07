import Foundation

/// Identifies one continuous connection to one camera.
///
/// Image App-era cameras all use `192.168.54.1` in Direct mode, so the host alone
/// cannot tell an old camera from a newly joined one. Requests carry the token of
/// the connection that created them and are refused once that connection ends.
struct CameraConnectionToken: Hashable, Sendable {
    let generation: UInt64
}

/// Thread-safe owner of the current camera connection generation.
///
/// `LumixClient` consults the scope before every request and after every reply,
/// so a delayed retry, a slow mode switch, or a late reply from an earlier
/// connection can never be applied to a camera that connected afterwards.
final class CameraConnectionScope: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var current: CameraConnectionToken {
        lock.withLock { CameraConnectionToken(generation: generation) }
    }

    /// Ends the current connection. Every token issued before this call becomes stale.
    @discardableResult
    func invalidate() -> CameraConnectionToken {
        lock.withLock {
            generation &+= 1
            return CameraConnectionToken(generation: generation)
        }
    }

    func isCurrent(_ token: CameraConnectionToken) -> Bool {
        lock.withLock { token.generation == generation }
    }
}
