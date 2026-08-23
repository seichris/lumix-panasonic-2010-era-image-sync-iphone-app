import CoreLocation
import Foundation

enum GoogleTimelineImporter {
    /// Google does not include a measurement accuracy for most Timeline
    /// visit/activity coordinates. Keep those matches explicitly uncertain,
    /// while still allowing the existing matcher to use them.
    static let estimatedHorizontalAccuracy: CLLocationAccuracy = 500

    enum ImportError: LocalizedError, Equatable {
        case invalidJSON
        case noUsableLocations

        var errorDescription: String? {
            switch self {
            case .invalidJSON:
                return "The selected file is not valid Google Timeline JSON."
            case .noUsableLocations:
                return "No usable location records were found. Select the location-history.json export from Google Maps."
            }
        }
    }

    static func samples(from fileURL: URL) throws -> [LocationSample] {
        try samples(from: Data(contentsOf: fileURL))
    }

    static func samples(from text: String) throws -> [LocationSample] {
        try samples(from: Data(text.utf8))
    }

    static func samples(from data: Data) throws -> [LocationSample] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportError.invalidJSON
        }

        var samples: [LocationSample] = []
        if let records = object as? [[String: Any]] {
            parseSegments(records, into: &samples)
        } else if let document = object as? [String: Any] {
            if let locations = document["locations"] as? [[String: Any]] {
                parseLocations(locations, into: &samples)
            }
            if let timelineObjects = document["timelineObjects"] as? [[String: Any]] {
                parseTimelineObjects(timelineObjects, into: &samples)
            }
            if let semanticSegments = document["semanticSegments"] as? [[String: Any]] {
                parseSegments(semanticSegments, into: &samples)
            }
        }

        let normalized = normalize(samples)
        guard !normalized.isEmpty else { throw ImportError.noUsableLocations }
        return normalized
    }

    private static func parseSegments(
        _ records: [[String: Any]],
        into samples: inout [LocationSample]
    ) {
        for record in records {
            let start = date(from: record["startTime"])
            let end = date(from: record["endTime"])

            if let visit = record["visit"] as? [String: Any],
               let candidate = visit["topCandidate"] as? [String: Any],
               let coordinate = coordinate(from: candidate["placeLocation"])
            {
                let accuracy = number(
                    candidate["accuracy"] ?? visit["accuracy"] ?? record["accuracy"]
                ) ?? estimatedHorizontalAccuracy
                append(
                    coordinate: coordinate,
                    timestamp: start ?? end,
                    altitude: number(candidate["altitude"]) ?? 0,
                    accuracy: accuracy,
                    into: &samples
                )
                append(
                    coordinate: coordinate,
                    timestamp: end ?? start,
                    altitude: number(candidate["altitude"]) ?? 0,
                    accuracy: accuracy,
                    into: &samples
                )
            }

            if let activity = record["activity"] as? [String: Any] {
                let accuracy = number(activity["accuracy"] ?? record["accuracy"])
                    ?? estimatedHorizontalAccuracy
                append(
                    coordinate: coordinate(from: activity["start"]),
                    timestamp: start,
                    altitude: number(activity["startAltitude"]) ?? 0,
                    accuracy: accuracy,
                    into: &samples
                )
                append(
                    coordinate: coordinate(from: activity["end"]),
                    timestamp: end,
                    altitude: number(activity["endAltitude"]) ?? 0,
                    accuracy: accuracy,
                    into: &samples
                )

                if let timelinePath = activity["timelinePath"] as? [[String: Any]] {
                    parseTimelinePath(
                        timelinePath,
                        startTime: start,
                        accuracy: accuracy,
                        into: &samples
                    )
                }
            }

            if let timelinePath = record["timelinePath"] as? [[String: Any]] {
                parseTimelinePath(
                    timelinePath,
                    startTime: start,
                    accuracy: number(record["accuracy"]) ?? estimatedHorizontalAccuracy,
                    into: &samples
                )
            }
        }
    }

    private static func parseTimelinePath(
        _ points: [[String: Any]],
        startTime: Date?,
        accuracy: Double,
        into samples: inout [LocationSample]
    ) {
        for point in points {
            let offsetMinutes = number(
                point["durationMinutesOffsetFromStartTime"] ?? point["offsetMinutes"]
            ) ?? 0
            let timestamp = startTime?.addingTimeInterval(offsetMinutes * 60)
            append(
                coordinate: coordinate(from: point["point"] ?? point["location"]),
                timestamp: timestamp,
                altitude: number(point["altitude"]) ?? 0,
                accuracy: number(point["accuracy"]) ?? accuracy,
                into: &samples
            )
        }
    }

    private static func parseLocations(
        _ locations: [[String: Any]],
        into samples: inout [LocationSample]
    ) {
        for location in locations {
            append(
                coordinate: coordinate(from: location),
                timestamp: date(
                    from: location["timestampMs"] ?? location["timestamp"]
                ),
                altitude: number(location["altitude"]) ?? 0,
                accuracy: number(location["accuracy"]) ?? estimatedHorizontalAccuracy,
                into: &samples
            )
        }
    }

    private static func parseTimelineObjects(
        _ objects: [[String: Any]],
        into samples: inout [LocationSample]
    ) {
        for object in objects {
            if let visit = object["placeVisit"] as? [String: Any] {
                let duration = visit["duration"] as? [String: Any]
                let start = date(from: duration?["startTimestampMs"] ?? duration?["startTimestamp"])
                let end = date(from: duration?["endTimestampMs"] ?? duration?["endTimestamp"])
                let coordinate = coordinate(
                    from: visit["location"] ?? visit["placeLocation"]
                )
                append(
                    coordinate: coordinate,
                    timestamp: start ?? end,
                    altitude: number(visit["altitude"]) ?? 0,
                    accuracy: number(visit["accuracy"]) ?? estimatedHorizontalAccuracy,
                    into: &samples
                )
                append(
                    coordinate: coordinate,
                    timestamp: end ?? start,
                    altitude: number(visit["altitude"]) ?? 0,
                    accuracy: number(visit["accuracy"]) ?? estimatedHorizontalAccuracy,
                    into: &samples
                )
            }

            guard let activity = object["activitySegment"] as? [String: Any] else { continue }
            let duration = activity["duration"] as? [String: Any]
            let start = date(from: duration?["startTimestampMs"] ?? duration?["startTimestamp"])
            let end = date(from: duration?["endTimestampMs"] ?? duration?["endTimestamp"])
            let accuracy = number(activity["accuracy"]) ?? estimatedHorizontalAccuracy
            append(
                coordinate: coordinate(from: activity["startLocation"]),
                timestamp: start,
                altitude: number(activity["startAltitude"]) ?? 0,
                accuracy: accuracy,
                into: &samples
            )
            append(
                coordinate: coordinate(from: activity["endLocation"]),
                timestamp: end,
                altitude: number(activity["endAltitude"]) ?? 0,
                accuracy: accuracy,
                into: &samples
            )
        }
    }

    private static func append(
        coordinate: (latitude: Double, longitude: Double)?,
        timestamp: Date?,
        altitude: Double,
        accuracy: Double,
        into samples: inout [LocationSample]
    ) {
        guard let coordinate, let timestamp,
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              abs(coordinate.latitude) <= 90,
              abs(coordinate.longitude) <= 180,
              altitude.isFinite,
              accuracy.isFinite,
              accuracy >= 0 else { return }

        samples.append(LocationSample(
            timestamp: timestamp,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: altitude,
            horizontalAccuracy: accuracy
        ))
    }

    private static func normalize(_ samples: [LocationSample]) -> [LocationSample] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var normalized: [LocationSample] = []
        normalized.reserveCapacity(sorted.count)

        for sample in sorted {
            if let previous = normalized.last,
               previous.timestamp == sample.timestamp,
               abs(previous.latitude - sample.latitude) < 0.0000001,
               abs(previous.longitude - sample.longitude) < 0.0000001
            {
                continue
            }
            normalized.append(sample)
        }
        return normalized
    }

    private static func date(from value: Any?) -> Date? {
        if let number = number(value) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        guard let string = value as? String else { return nil }
        if let number = Double(string) {
            let seconds = number > 10_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    private static func coordinate(from value: Any?) -> (latitude: Double, longitude: Double)? {
        if let string = value as? String {
            return coordinate(from: string)
        }

        guard let dictionary = value as? [String: Any] else { return nil }
        if let latLng = dictionary["latLng"] as? String,
           let coordinate = coordinate(from: latLng) {
            return coordinate
        }

        let latitude = number(dictionary["latitude"] ?? dictionary["lat"])
            ?? number(dictionary["latitudeE7"]).map { $0 / 10_000_000 }
        let longitude = number(dictionary["longitude"] ?? dictionary["lng"])
            ?? number(dictionary["longitudeE7"]).map { $0 / 10_000_000 }
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    private static func coordinate(from string: String) -> (latitude: Double, longitude: Double)? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("geo:") {
            value.removeFirst(4)
        }
        value = value.replacingOccurrences(of: "°", with: "")
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let latitudeString = value[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        let remaining = value[value.index(after: comma)...]
        let longitudeString = remaining
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let longitudeString,
              let latitude = Double(latitudeString),
              let longitude = Double(longitudeString) else { return nil }
        return (latitude, longitude)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
