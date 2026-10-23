import Foundation

enum LocationTrackingAction: String {
    case start, stop

    var url: URL { URL(string: "gm1sync://tracking/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme == "gm1sync", url.host == "tracking",
              url.query == nil, url.fragment == nil,
              let action = Self(rawValue: String(url.path.dropFirst())) else { return nil }
        self = action
    }
}

/// Only a status flag is shared with the widget. The location track stays in the app.
enum LocationTrackingWidgetState: String {
    case off, recording, awaitingPermission

    static let kind = "LocationTrackingWidget"
    static let appGroup = "group.com.web3.gm1sync"
    private static let statusKey = "locationTrackingWidgetStatus"

    static func read(from defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> Self {
        defaults?.string(forKey: statusKey).flatMap(Self.init(rawValue:)) ?? .off
    }

    func save(to defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        defaults?.set(rawValue, forKey: Self.statusKey)
    }

    var action: LocationTrackingAction { self == .off ? .start : .stop }

    var title: String {
        switch self {
        case .off: "Off"
        case .recording: "On"
        case .awaitingPermission: "Needs permission"
        }
    }
}
