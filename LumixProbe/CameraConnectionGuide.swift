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
                    title: "Join from this iPhone",
                    detail: "Connect to the camera Wi-Fi by scanning the QR code, or manually."
                )
            }

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
            rememberedCameraSSID: "GM1S-90C7E0",
            reconnect: {},
            scanQRCode: {},
            joinManually: {}
        )
    }
}
