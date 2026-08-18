import SwiftUI

struct CameraConnectionGuide: View {
    let statusMessage: String
    let rememberedCameraSSID: String?
    let reconnect: () -> Void
    let scanQRCode: () -> Void
    let joinManually: () -> Void
    @State private var showsConnectionSteps = false

    var body: some View {
        Section {
            if showsConnectionSteps {
                connectionStep(
                    number: 1,
                    title: "Enable the camera Wi-Fi",
                    detail: "On the camera choose Wi-Fi → New Connection → Remote Shooting & View."
                )

                connectionStep(
                    number: 2,
                    title: joinTitle,
                    detail: joinDetail
                )
            }

#if os(iOS)
            if let rememberedCameraSSID {
                Button(action: reconnect) {
                    Label("Reconnect to \(rememberedCameraSSID)", systemImage: "wifi")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(connectionActionInsets)
                .accessibilityIdentifier("reconnect-remembered-camera")

                Button(action: scanQRCode) {
                    Label("Scan another camera QR code", systemImage: "qrcode.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .listRowInsets(connectionActionInsets)
                .accessibilityIdentifier("scan-camera-qr-code")
            } else {
                Button(action: scanQRCode) {
                    Label("Scan camera QR code", systemImage: "qrcode.viewfinder")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(connectionActionInsets)
                .accessibilityIdentifier("scan-camera-qr-code")
            }

            Button(action: joinManually) {
                Label("Enter wi-fi name and password", systemImage: "keyboard")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .listRowInsets(connectionActionInsets)
            .accessibilityIdentifier("join-camera-wifi-manually")
#else
            Label("Join the camera network from the Mac Wi-Fi menu before probing.", systemImage: "wifi")
                .font(.subheadline)
                .foregroundStyle(.secondary)
#endif

            Label(statusMessage, systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Connect the camera")
                Spacer()
                Button {
                    withAnimation { showsConnectionSteps.toggle() }
                } label: {
                    Image(systemName: showsConnectionSteps ? "questionmark.circle.fill" : "questionmark.circle")
                        .imageScale(.large)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsConnectionSteps ? "Hide connection steps" : "Show connection steps")
                .accessibilityIdentifier("camera-connection-help")
            }
        }
    }

    private var joinTitle: String {
#if os(iOS)
        return "Join from this iPhone"
#else
        return "Join the camera Wi-Fi"
#endif
    }

    private var joinDetail: String {
#if os(iOS)
        return "Connect to the camera Wi-Fi by scanning the QR code, or manually."
#else
        return "Use the Wi-Fi menu in the macOS menu bar to join the SSID shown by the camera, then return here."
#endif
    }

    private var connectionActionInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
    }

    private func connectionStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Disconnected camera") {
    List {
        CameraConnectionGuide(
            statusMessage: "Join the Wi-Fi network shown by the camera.",
            rememberedCameraSSID: "GM1S-DEMO01",
            reconnect: {},
            scanQRCode: {},
            joinManually: {}
        )
    }
}
