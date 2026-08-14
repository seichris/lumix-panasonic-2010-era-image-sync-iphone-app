import SwiftUI

struct CameraConnectionGuide: View {
    let statusMessage: String
    let rememberedCameraSSID: String?
    let reconnect: () -> Void
    let scanQRCode: () -> Void
    let joinManually: () -> Void

    var body: some View {
        Section("Connect the camera") {
            connectionStep(
                number: 1,
                title: "Enable the camera Wi-Fi",
                detail: "On the camera choose Wi-Fi → New Connection → Remote Shooting & View. Leave its QR code on screen."
            )

            connectionStep(
                number: 2,
                title: "Join from this iPhone",
                detail: connectionDetail
            )

            if let rememberedCameraSSID {
                Button(action: reconnect) {
                    Label("Reconnect to \(rememberedCameraSSID)", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reconnect-remembered-camera")

                Text("This camera is remembered securely. iPhone can also Auto-Join it whenever its Wi-Fi is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(action: scanQRCode) {
                    Label("Scan another camera QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("scan-camera-qr-code")
            } else {
                Button(action: scanQRCode) {
                    Label("Scan camera QR code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scan-camera-qr-code")
            }

            Button("Enter network details", action: joinManually)
                .accessibilityIdentifier("join-camera-wifi-manually")

            Label(statusMessage, systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionDetail: String {
        if let rememberedCameraSSID {
            "Turn on the camera Wi-Fi. iPhone should Auto-Join \(rememberedCameraSSID); if it does not, reconnect below."
        } else {
            "Scan the camera QR code below, or manually join the SSID shown by the camera in iPhone Settings."
        }
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
