import Foundation

/// One JPEG received through Send Images While Recording.
struct CameraPushTransferRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let filename: String
    let byteCount: Int64
    let sha256: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    let receivedAt: Date
    var savedToPhotosAt: Date?
    /// True once a gallery import found the card original byte-identical to this
    /// transfer. Until then the transfer is treated as a copy of unknown quality.
    var matchesCardOriginal = false
    let source: String?

    init(
        id: UUID = UUID(),
        filename: String,
        byteCount: Int64,
        sha256: String,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        receivedAt: Date,
        savedToPhotosAt: Date? = nil,
        matchesCardOriginal: Bool = false,
        source: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.receivedAt = receivedAt
        self.savedToPhotosAt = savedToPhotosAt
        self.matchesCardOriginal = matchesCardOriginal
        self.source = source
    }

    var normalizedFilename: String { Self.normalize(filename) }

    static func normalize(_ filename: String) -> String {
        filename.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

protocol CameraPushTransferHistoryStoring: AnyObject {
    func load() throws -> [CameraPushTransferRecord]
    func save(_ records: [CameraPushTransferRecord]) throws
}

final class UserDefaultsCameraPushTransferHistoryStore: CameraPushTransferHistoryStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "cameraPushTransferHistory.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [CameraPushTransferRecord] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([CameraPushTransferRecord].self, from: data)
    }

    func save(_ records: [CameraPushTransferRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }
}

final class InMemoryCameraPushTransferHistoryStore: CameraPushTransferHistoryStoring {
    private var records: [CameraPushTransferRecord]

    init(records: [CameraPushTransferRecord] = []) {
        self.records = records
    }

    func load() throws -> [CameraPushTransferRecord] { records }
    func save(_ records: [CameraPushTransferRecord]) throws { self.records = records }
}

/// Shared by the receiving session (duplicate detection) and the camera gallery
/// (original-quality comparison during import).
@MainActor
final class CameraPushTransferHistory: ObservableObject {
    static let maximumRecords = 5_000

    @Published private(set) var records: [CameraPushTransferRecord]
    private let store: any CameraPushTransferHistoryStoring

    init(store: any CameraPushTransferHistoryStoring = UserDefaultsCameraPushTransferHistoryStore()) {
        self.store = store
        records = (try? store.load()) ?? []
    }

    /// A transfer of exactly these bytes that Photos already saved. A SHA-256 match
    /// means the same file, whatever name the camera or its media server used.
    func savedRecord(sha256: String) -> CameraPushTransferRecord? {
        records.last { $0.sha256 == sha256 && $0.savedToPhotosAt != nil }
    }

    func append(_ record: CameraPushTransferRecord) {
        var updated = records + [record]
        if updated.count > Self.maximumRecords { updated.removeFirst(updated.count - Self.maximumRecords) }
        persist(updated)
    }

    func markMatchesCardOriginal(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].matchesCardOriginal else { return }
        var updated = records
        updated[index].matchesCardOriginal = true
        persist(updated)
    }

    private func persist(_ updated: [CameraPushTransferRecord]) {
        do {
            try store.save(updated)
        } catch {
            print("[GM1Sync] Transfer history could not be saved: \(error.localizedDescription)")
        }
        records = updated
    }
}
