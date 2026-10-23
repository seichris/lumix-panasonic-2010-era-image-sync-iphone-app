import SwiftUI
import WidgetKit

private struct TrackingEntry: TimelineEntry {
    let date: Date
    let state: LocationTrackingWidgetState
}

private struct TrackingProvider: TimelineProvider {
    func placeholder(in context: Context) -> TrackingEntry {
        TrackingEntry(date: .now, state: .off)
    }

    func getSnapshot(in context: Context, completion: @escaping (TrackingEntry) -> Void) {
        completion(TrackingEntry(date: .now, state: .read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrackingEntry>) -> Void) {
        completion(Timeline(entries: [TrackingEntry(date: .now, state: .read())], policy: .never))
    }
}

private struct TrackingWidgetView: View {
    let entry: TrackingEntry

    private var isOn: Bool { entry.state == .recording }
    private var status: String {
        switch entry.state {
        case .off: "Off"
        case .recording: "On"
        case .awaitingPermission: "Needs permission"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: isOn ? "location.fill" : "location.slash")
                    .font(.title2)
                Spacer()
                Image(systemName: "power")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(isOn ? Color.green : Color.secondary)

            Spacer(minLength: 0)

            Text("Geotagging")
                .font(.headline)
            Text(status)
                .font(.title2.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(entry.state.action == .start ? "Tap to turn on" : "Tap to turn off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(entry.state.action.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geotagging \(status)")
        .accessibilityHint(entry.state.action == .start
            ? "Opens Retro LUMIX Sync and starts location tracking."
            : "Opens Retro LUMIX Sync and stops location tracking.")
    }
}

@main
struct LocationTrackingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LocationTrackingWidgetState.kind, provider: TrackingProvider()) { entry in
            TrackingWidgetView(entry: entry)
        }
        .configurationDisplayName("Geotagging")
        .description("Tap to open Retro LUMIX Sync and turn location tracking on or off.")
        .supportedFamilies([.systemSmall])
    }
}
