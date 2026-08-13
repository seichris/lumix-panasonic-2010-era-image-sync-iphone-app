import SwiftUI

struct CameraConnectionGuide: View {
    let statusMessage: String
    let scanQRCode: () -> Void

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
                detail: "Scan the camera QR code below, or manually join the SSID shown by the camera in iPhone Settings."
            )

            Button(action: scanQRCode) {
                Label("Scan camera QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("scan-camera-qr-code")

            Label(statusMessage, systemImage: "wifi.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
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
