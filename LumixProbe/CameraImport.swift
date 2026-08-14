import CoreLocation
import Foundation
import Photos

enum CameraPhotoImportMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case jpeg
    case jpegAndRAW
    case raw

    var id: Self { self }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .jpegAndRAW: "JPEG + RAW"
        case .raw: "RAW"
        }
    }
}

enum CameraImportVariant: String, Codable, Hashable, Sendable {
    case jpeg
    case jpegAndRAW
    case raw
    case video

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .jpegAndRAW: "JPEG + RAW"
        case .raw: "RAW"
        case .video: "Video"
        }
    }
}

struct CameraImportPlan: Sendable {
    struct Resource: Sendable {
        enum Role: Hashable, Sendable {
            case photo
            case alternatePhoto
            case video
        }

        let cameraResource: LumixResource
        let role: Role
    }

    let variant: CameraImportVariant
    let resources: [Resource]
}

extension LumixPhoto {
    func supports(_ mode: CameraPhotoImportMode) -> Bool {
        guard kind == .photo else { return true }
        switch mode {
        case .jpeg: return originalJPEGResource != nil
        case .jpegAndRAW: return originalJPEGResource != nil && rawResource != nil
        case .raw: return rawResource != nil
        }
    }

    func importPlan(photoMode: CameraPhotoImportMode) throws -> CameraImportPlan {
        if kind == .video {
            guard let videoResource else { throw LumixError.noVideo }
            return CameraImportPlan(
                variant: .video,
                resources: [.init(cameraResource: videoResource, role: .video)]
            )
        }

        switch photoMode {
        case .jpeg:
            guard let originalJPEGResource else { throw LumixError.noOriginalJPEG }
            return CameraImportPlan(
                variant: .jpeg,
                resources: [.init(cameraResource: originalJPEGResource, role: .photo)]
            )

        case .jpegAndRAW:
            guard let originalJPEGResource else { throw LumixError.noOriginalJPEG }
            guard let rawResource else { throw LumixError.noRAW }
            return CameraImportPlan(
                variant: .jpegAndRAW,
                resources: [
                    .init(cameraResource: originalJPEGResource, role: .photo),
                    .init(cameraResource: rawResource, role: .alternatePhoto)
                ]
            )

        case .raw:
            guard let rawResource else { throw LumixError.noRAW }
            return CameraImportPlan(
                variant: .raw,
                resources: [.init(cameraResource: rawResource, role: .photo)]
            )
        }
    }
}

struct DownloadedCameraMedia: Sendable {
    struct Resource: Sendable {
        let fileURL: URL
        let originalFilename: String
        let role: CameraImportPlan.Resource.Role
    }

    let variant: CameraImportVariant
    let resources: [Resource]
    let captureDate: Date?
}

protocol CameraMediaImporting: Sendable {
    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws
}

struct SystemCameraMediaImporter: CameraMediaImporting {
    func save(_ media: DownloadedCameraMedia, geotag: GeotagMatch?) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CameraMediaImportError.permissionDenied
        }

        let resourceTypes = media.resources.map { NSNumber(value: $0.role.photoKitType.rawValue) }
        guard PHAssetCreationRequest.supportsAssetResourceTypes(resourceTypes) else {
            throw CameraMediaImportError.unsupportedResourceCombination
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = media.captureDate
            request.location = geotag?.location

            for resource in media.resources {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = resource.originalFilename
                options.shouldMoveFile = false
                request.addResource(
                    with: resource.role.photoKitType,
                    fileURL: resource.fileURL,
                    options: options
                )
            }
        }
    }
}

private extension CameraImportPlan.Resource.Role {
    var photoKitType: PHAssetResourceType {
        switch self {
        case .photo: .photo
        case .alternatePhoto: .alternatePhoto
        case .video: .video
        }
    }
}

enum CameraMediaImportError: LocalizedError {
    case permissionDenied
    case unsupportedResourceCombination

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Photos permission is required to import camera media."
        case .unsupportedResourceCombination:
            "Photos does not support this camera media combination on this iPhone."
        }
    }
}

struct CameraImportHistoryRecord: Codable, Equatable, Sendable {
    var variants: Set<CameraImportVariant>
    var lastImportedAt: Date

    var summary: String {
        variants
            .sorted { $0.title < $1.title }
            .map(\.title)
            .joined(separator: ", ")
    }
}

protocol CameraImportHistoryStoring: AnyObject {
    func load() throws -> [String: CameraImportHistoryRecord]
    func save(_ records: [String: CameraImportHistoryRecord]) throws
}

final class UserDefaultsCameraImportHistoryStore: CameraImportHistoryStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "cameraImportHistory.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [String: CameraImportHistoryRecord] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: CameraImportHistoryRecord].self, from: data)
    }

    func save(_ records: [String: CameraImportHistoryRecord]) throws {
        defaults.set(try JSONEncoder().encode(records), forKey: key)
    }
}

final class InMemoryCameraImportHistoryStore: CameraImportHistoryStoring {
    private var records: [String: CameraImportHistoryRecord]

    init(records: [String: CameraImportHistoryRecord] = [:]) {
        self.records = records
    }

    func load() throws -> [String: CameraImportHistoryRecord] { records }

    func save(_ records: [String: CameraImportHistoryRecord]) throws {
        self.records = records
    }
}
