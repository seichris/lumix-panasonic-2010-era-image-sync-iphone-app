import SwiftUI

struct ContentView: View {
    @StateObject private var model = ProbeViewModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Camera") {
                    TextField("Camera IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                    Text("Connect the iPhone to the GM1S Wi-Fi first. The default probe address is 192.168.54.1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Protocol tests") {
                    Button("Probe getstate") { model.probeState() }
                    Button("Request camera access") { model.requestAccess() }
                    Button("Run full probe") { model.runFullProbe() }
                        .fontWeight(.semibold)
                    Button("Browse final 5 records") { model.browseLastFive() }
                    Button("Download first original JPEG") { model.downloadFirstOriginal() }
                        .disabled(model.isRunning)
                    if model.downloadedFile != nil {
                        Button("Save downloaded original to Photos") { model.saveDownloadedToPhotos() }
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
        }
    }
}
