import Foundation

protocol CameraLocationOverrideStoring: AnyObject {
    func load() throws -> [String: PhotoGeotagLocation]
    func save(_ overrides: [String: PhotoGeotagLocation]) throws
}

final class UserDefaultsCameraLocationOverrideStore: CameraLocationOverrideStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "cameraLocationOverrides.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [String: PhotoGeotagLocation] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return try JSONDecoder().decode([String: PhotoGeotagLocation].self, from: data)
    }

    func save(_ overrides: [String: PhotoGeotagLocation]) throws {
        defaults.set(try JSONEncoder().encode(overrides), forKey: key)
    }
}

final class InMemoryCameraLocationOverrideStore: CameraLocationOverrideStoring {
    private var overrides: [String: PhotoGeotagLocation]

    init(overrides: [String: PhotoGeotagLocation] = [:]) {
        self.overrides = overrides
    }

    func load() throws -> [String: PhotoGeotagLocation] { overrides }

    func save(_ overrides: [String: PhotoGeotagLocation]) throws {
        self.overrides = overrides
    }
}

enum CameraLocationOverrideError: LocalizedError {
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            return "The selected map location is not a valid coordinate."
        }
    }
}
