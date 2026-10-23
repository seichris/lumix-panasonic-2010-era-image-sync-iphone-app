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

    var body: some View {
        LocationTrackingWidgetContent(state: entry.state)
            .containerBackground(.background, for: .widget)
            .widgetURL(entry.state.action.url)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Geotagging \(entry.state.title)")
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
