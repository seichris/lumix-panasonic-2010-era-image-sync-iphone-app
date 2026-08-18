import SwiftUI
#if os(iOS)
import VisionKit
#endif

#if os(iOS)
struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onScanned: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRCodeScannerView { payload in
                        dismiss()
                        onScanned(payload)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point the iPhone at the QR code shown on the camera.")
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Scanner unavailable",
                        systemImage: "camera.fill",
                        description: Text("Join the camera network manually in iPhone Wi-Fi Settings.")
                    )
                }
            }
            .navigationTitle("Scan camera Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
#else
/// macOS has no camera-backed VisionKit scanner in this app. Camera Wi-Fi can
/// be joined from the macOS Wi-Fi menu before probing the configured address.
struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onScanned: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
            Text("Join the camera Wi-Fi on your Mac")
                .font(.title3.weight(.semibold))
            Text("Use the Wi-Fi menu in the macOS menu bar to join the SSID shown on the camera, then return to GM1 Sync and probe the camera address.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 280)
        .navigationTitle("Connect camera Wi-Fi")
    }
}
#endif

#if os(iOS)
private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        Task { @MainActor in try? controller.startScanning() }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        try? controller.startScanning()
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScanned: (String) -> Void
        private var hasScanned = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue else { continue }
                hasScanned = true
                dataScanner.stopScanning()
                onScanned(payload)
                return
            }
        }
    }
}
#endif
