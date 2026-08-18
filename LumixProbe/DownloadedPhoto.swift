import Foundation

struct DownloadedPhoto: Equatable, Sendable {
    let fileURL: URL
    let captureDate: Date?
    let originalFilename: String
}
