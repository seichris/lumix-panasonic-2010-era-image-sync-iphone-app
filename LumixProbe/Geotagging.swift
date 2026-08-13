import CoreLocation
import Foundation
import ImageIO
import Photos

struct LocationSample: Codable, Hashable, Identifiable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double

    var id: Date { timestamp }

    init(location: CLLocation) {
        timestamp = location.timestamp
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.altitude
        horizontalAccuracy = location.horizontalAccuracy
    }

    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        horizontalAccuracy: Double
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }
}

struct GeotagMatch: Hashable, Sendable {
    enum Method: String, Hashable, Sendable {
        case interpolated = "Interpolated track point"
        case nearest = "Nearest track point"
    }

    enum Quality: String, Hashable, Sendable {
        case excellent = "Excellent match"
        case good = "Good match"
        case uncertain = "Check this match"
    }

    let captureDate: Date
    let adjustedCaptureDate: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let nearestSampleTimeDifference: TimeInterval
    let method: Method
    let quality: Quality

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: adjustedCaptureDate
        )
    }
}

enum LocationTrackMatcher {
    static let defaultMaximumTimeDifference: TimeInterval = 15 * 60
    static let maximumUsableAccuracy: CLLocationAccuracy = 500

    static func match(
        captureDate: Date,
        samples: [LocationSample],
        cameraClockOffset: TimeInterval = 0,
        maximumTimeDifference: TimeInterval = defaultMaximumTimeDifference
    ) -> GeotagMatch? {
        let adjustedCaptureDate = captureDate.addingTimeInterval(cameraClockOffset)
        let usable = samples
            .filter {
                $0.horizontalAccuracy >= 0 &&
                    $0.horizontalAccuracy <= maximumUsableAccuracy &&
                    $0.latitude.isFinite &&
                    $0.longitude.isFinite
            }
            .sorted { $0.timestamp < $1.timestamp }

        guard !usable.isEmpty else { return nil }

        let before = usable.last { $0.timestamp <= adjustedCaptureDate }
        let after = usable.first { $0.timestamp >= adjustedCaptureDate }

        if let before,
           let after,
           before.timestamp != after.timestamp,
           adjustedCaptureDate.timeIntervalSince(before.timestamp) <= maximumTimeDifference,
           after.timestamp.timeIntervalSince(adjustedCaptureDate) <= maximumTimeDifference {
            let interval = after.timestamp.timeIntervalSince(before.timestamp)
            let progress = adjustedCaptureDate.timeIntervalSince(before.timestamp) / interval
            let accuracy = max(before.horizontalAccuracy, after.horizontalAccuracy)
            let nearestDifference = min(
                adjustedCaptureDate.timeIntervalSince(before.timestamp),
                after.timestamp.timeIntervalSince(adjustedCaptureDate)
            )

            return GeotagMatch(
                captureDate: captureDate,
                adjustedCaptureDate: adjustedCaptureDate,
                latitude: interpolate(before.latitude, after.latitude, progress: progress),
                longitude: interpolate(before.longitude, after.longitude, progress: progress),
                altitude: interpolate(before.altitude, after.altitude, progress: progress),
                horizontalAccuracy: accuracy,
                nearestSampleTimeDifference: nearestDifference,
                method: .interpolated,
                quality: quality(accuracy: accuracy, timeDifference: nearestDifference)
            )
        }

        guard let nearest = usable.min(by: {
            abs($0.timestamp.timeIntervalSince(adjustedCaptureDate)) <
                abs($1.timestamp.timeIntervalSince(adjustedCaptureDate))
        }) else { return nil }

        let timeDifference = abs(nearest.timestamp.timeIntervalSince(adjustedCaptureDate))
        guard timeDifference <= maximumTimeDifference else { return nil }

        return GeotagMatch(
            captureDate: captureDate,
            adjustedCaptureDate: adjustedCaptureDate,
            latitude: nearest.latitude,
            longitude: nearest.longitude,
            altitude: nearest.altitude,
            horizontalAccuracy: nearest.horizontalAccuracy,
            nearestSampleTimeDifference: timeDifference,
            method: .nearest,
            quality: quality(accuracy: nearest.horizontalAccuracy, timeDifference: timeDifference)
        )
    }

    private static func interpolate(_ start: Double, _ end: Double, progress: Double) -> Double {
        start + ((end - start) * min(max(progress, 0), 1))
    }

    private static func quality(accuracy: Double, timeDifference: TimeInterval) -> GeotagMatch.Quality {
        if accuracy <= 50, timeDifference <= 30 { return .excellent }
        if accuracy <= 100, timeDifference <= 120 { return .good }
        return .uncertain
    }
}

enum PhotoCaptureDateReader {
    static func read(from fileURL: URL, fallbackTimeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ??
            exif?[kCGImagePropertyExifDateTimeDigitized] as? String ??
            tiff?[kCGImagePropertyTIFFDateTime] as? String
        let offsetString = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String

        guard let dateString else { return nil }
        return parse(dateString, offset: offsetString, fallbackTimeZone: fallbackTimeZone)
    }

    static func parse(
        _ dateString: String,
        offset: String?,
        fallbackTimeZone: TimeZone
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(from:)) ?? fallbackTimeZone
        return formatter.date(from: dateString)
    }

    private static func timeZone(from offset: String) -> TimeZone? {
        if offset == "Z" { return TimeZone(secondsFromGMT: 0) }

        let sign: Int
        if offset.hasPrefix("+") {
            sign = 1
        } else if offset.hasPrefix("-") {
            sign = -1
        } else {
            return nil
        }

        let components = offset.dropFirst().split(separator: ":")
        guard components.count == 2,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              hours <= 23,
              minutes <= 59 else { return nil }
        return TimeZone(secondsFromGMT: sign * ((hours * 60 + minutes) * 60))
    }
}

@MainActor
final class GeotagLocationLogger: NSObject, ObservableObject {
    @Published private(set) var samples: [LocationSample] = []
    @Published private(set) var isLogging = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var statusMessage = "Location logging is off."
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private let storageURL: URL
    private var shouldStartAfterAuthorization = false
    private var lastPersistedAt = Date.distantPast

    override init() {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        storageURL = supportDirectory.appendingPathComponent("GM1Sync-location-track.json")
        authorizationStatus = manager.authorizationStatus
        super.init()

        manager.delegate = self
        manager.activityType = .other
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        loadTrack()
    }

    var latestSample: LocationSample? { samples.last }

    var hasPreciseLocation: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else {
            statusMessage = "Location Services are disabled in iPhone Settings."
            return
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            shouldStartAfterAuthorization = true
            statusMessage = "Waiting for location permission…"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginUpdates()
        case .denied, .restricted:
            statusMessage = "Allow location access in Settings to record a geotag track."
        @unknown default:
            statusMessage = "Location permission is unavailable."
        }
    }

    func stop() {
        shouldStartAfterAuthorization = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isLogging = false
        statusMessage = samples.isEmpty
            ? "Location log stopped without any usable samples."
            : "Location log stopped with \(samples.count) samples."
        persistTrack()
    }

    func clear() {
        guard !isLogging else {
            statusMessage = "Stop location logging before clearing the track."
            return
        }
        samples = []
        startedAt = nil
        try? FileManager.default.removeItem(at: storageURL)
        statusMessage = "Location track cleared."
    }

    private func beginUpdates() {
        guard !isLogging else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isLogging = true
        startedAt = Date()
        statusMessage = hasPreciseLocation
            ? "Recording location, including while this iPhone is locked."
            : "Recording approximate location. Enable Precise Location for better geotags."
    }

    private func accept(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= LocationTrackMatcher.maximumUsableAccuracy,
              abs(location.timestamp.timeIntervalSinceNow) <= 120 else { return }

        if let previous = samples.last {
            guard location.timestamp > previous.timestamp else { return }
            if location.timestamp.timeIntervalSince(previous.timestamp) < 4,
               location.distance(from: previous.location) < 10 {
                return
            }
        }

        samples.append(LocationSample(location: location))
        if samples.count > 20_000 {
            samples.removeFirst(samples.count - 20_000)
        }
        statusMessage = "Recording · latest accuracy ±\(Int(location.horizontalAccuracy.rounded())) m"

        if Date().timeIntervalSince(lastPersistedAt) >= 30 {
            persistTrack()
        }
    }

    private func loadTrack() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([LocationSample].self, from: data) else { return }
        samples = decoded.sorted { $0.timestamp < $1.timestamp }
        statusMessage = "Loaded \(samples.count) saved location samples."
    }

    private func persistTrack() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(samples)
            try data.write(to: storageURL, options: .atomic)
            lastPersistedAt = Date()
        } catch {
            statusMessage = "Could not save the location track: \(error.localizedDescription)"
        }
    }
}

extension GeotagLocationLogger: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard shouldStartAfterAuthorization else { return }

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            shouldStartAfterAuthorization = false
            beginUpdates()
        case .denied, .restricted:
            shouldStartAfterAuthorization = false
            statusMessage = "Location permission was not granted."
        case .notDetermined:
            break
        @unknown default:
            shouldStartAfterAuthorization = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations { accept(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        statusMessage = "Location update failed: \(error.localizedDescription)"
    }
}

enum PhotosOriginalImporter {
    enum ImportError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            "Photos permission is required to save the downloaded original."
        }
    }

    static func save(
        fileURL: URL,
        originalFilename: String,
        captureDate: Date?,
        location: CLLocation?
    ) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ImportError.permissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = captureDate
            request.location = location

            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalFilename
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        }
    }
}
