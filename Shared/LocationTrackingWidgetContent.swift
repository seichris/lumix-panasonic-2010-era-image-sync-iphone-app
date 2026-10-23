#if os(iOS)
import SwiftUI

/// The setup guide previews the same content that appears on the Home Screen.
struct LocationTrackingWidgetContent: View {
    let state: LocationTrackingWidgetState

    private var isOn: Bool { state == .recording }
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
            Text(state.title)
                .font(.title2.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(state.action == .start ? "Tap to turn on" : "Tap to turn off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
