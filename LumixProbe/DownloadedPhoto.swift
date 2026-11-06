import Foundation

final class DownloadedPhoto: Sendable {
    let fileURL: URL
    let captureDate: Date?
    let originalFilename: String

    init(fileURL: URL, captureDate: Date?, originalFilename: String) {
        self.fileURL = fileURL
        self.captureDate = captureDate
        self.originalFilename = originalFilename
    }

    deinit {
        // The diagnostic preview and any in-flight save share ownership of this temporary download.
        try? FileManager.default.removeItem(at: fileURL)
    }
}
