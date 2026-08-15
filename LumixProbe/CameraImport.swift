import CoreLocation
import Foundation
import Photos
import UniformTypeIdentifiers

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

struct CameraMediaPolicy: Hashable, Sendable {
    let capabilities: CameraCapabilities?

    init(capabilities: CameraCapabilities? = nil) {
        self.capabilities = capabilities
    }

    func supportsImport(of photo: LumixPhoto, photoMode: CameraPhotoImportMode) -> Bool {
        guard photo.kind == .video else { return photo.supports(photoMode) }
        return importResource(for: photo) != nil
    }

    func importResource(for photo: LumixPhoto) -> LumixResource? {
        let candidates = photo.resources
            .filter { $0.isVideo && !$0.isPreview }
            .sorted { videoImportPriority($0) < videoImportPriority($1) }

        return candidates.first { resource in
            if resource.isAVCHD {
                // Panasonic documents GM1S AVCHD as playback-only. Only an
                // affirmative exact camera capability may override that.
                return capabilities?.copyAllowed(for: resource) == true
            }
            if let explicit = capabilities?.copyAllowed(for: resource) {
                return explicit
            }
            // Older capability documents can omit MP4 copy actions even though
            // Image App-era cameras support the ordinary MP4 copy path.
            return resource.isPhoneCopyableVideoFormat
        }
    }

    func supportsPlayback(of resource: LumixResource) -> Bool {
        capabilities?.playbackCapability(for: resource)?.enabled ?? true
    }

    private func videoImportPriority(_ resource: LumixResource) -> Int {
        if resource.isPhoneCopyableVideoFormat { return 0 }
        if resource.isAVCHD { return 10 }
        return 20
    }
}

extension LumixPhoto {
    func supports(_ mode: CameraPhotoImportMode) -> Bool {
        guard kind == .photo else { return isImportable }
        switch mode {
        case .jpeg: return originalJPEGResource != nil
        case .jpegAndRAW: return originalJPEGResource != nil && rawResource != nil
        case .raw: return rawResource != nil
        }
    }

    func importPlan(
        photoMode: CameraPhotoImportMode,
        policy: CameraMediaPolicy = CameraMediaPolicy()
    ) throws -> CameraImportPlan {
        if kind == .video {
            guard videoResource != nil else { throw LumixError.noVideo }
            guard let videoResource = policy.importResource(for: self) else {
                throw LumixError.videoImportNotSupported
            }
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
                options.uniformTypeIdentifier = resource.role.uniformTypeIdentifier(
                    for: resource.originalFilename
                )
                options.shouldMoveFile = resource.role == .video
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

    func uniformTypeIdentifier(for filename: String) -> String? {
        guard self == .video else { return nil }
        switch (filename as NSString).pathExtension.lowercased() {
        case "mts", "m2ts":
            return UTType.mpeg2TransportStream.identifier
        case "mp4":
            return UTType.mpeg4Movie.identifier
        case "mov":
            return UTType.quickTimeMovie.identifier
        case "m4v":
            return UTType(filenameExtension: "m4v")?.identifier
        default:
            return UTType(filenameExtension: (filename as NSString).pathExtension)?.identifier
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
