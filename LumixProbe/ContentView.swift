import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ProbeViewModel()
    @State private var presentedSheet: ConnectionSheet?

    var body: some View {
        NavigationStack {
            List {
                if !model.isCameraConnected {
                    CameraConnectionGuide(
                        statusMessage: model.connectionStatusMessage,
                        scanQRCode: { presentedSheet = .qrScanner }
                    )
                }

                Section("Camera") {
                    if model.isCameraConnected {
                        Label("Connected to GM1S", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    TextField("Camera IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    Text("The default GM1S address is 192.168.54.1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Protocol tests") {
                    Button("Probe getstate") { model.probeState() }
                    Button("Request camera access") { model.requestAccess() }
                    Button("Run full probe") { model.runFullProbe() }
                        .fontWeight(.semibold)
                    Button("Probe media server directly") { model.browseFirstFiveDirectly() }
                    Button("Browse final 5 records") { model.browseLastFive() }
                    Button("Download first original JPEG") { model.downloadFirstOriginal() }
                        .disabled(model.isRunning)
                    if model.downloadedFile != nil {
                        Button("Save downloaded original to Photos") { model.saveDownloadedToPhotos() }
                    }
                    LabeledContent("Last result") {
                        Text(model.lastResult)
                            .accessibilityIdentifier("lastResult")
                    }
                }
                .disabled(model.isRunning)

                if !model.resources.isEmpty {
                    Section("Advertised resources") {
                        ForEach(model.resources) { resource in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(resource.profileName ?? "Unknown profile").font(.headline)
                                Text(resource.title ?? resource.url.lastPathComponent).font(.subheadline)
                                Text(resource.url.absoluteString)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Raw probe log").font(.headline)
                        Spacer()
                        Button("Clear") { model.clearLog() }.font(.caption)
                    }
                    Text(model.log)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Lumix GM1S Probe")
            .overlay {
                if model.isRunning { ProgressView().controlSize(.large) }
            }
            .task { await model.refreshConnectionStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.refreshConnectionStatus() }
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .qrScanner:
                    QRCodeScannerSheet { payload in
                        Task { await model.joinCameraWiFi(qrPayload: payload) }
                    }
                }
            }
        }
    }
}

private enum ConnectionSheet: String, Identifiable {
    case qrScanner

    var id: String { rawValue }
}
