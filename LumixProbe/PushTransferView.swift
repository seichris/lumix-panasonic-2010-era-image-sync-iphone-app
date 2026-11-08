import SwiftUI
import UIKit

/// Send Images While Recording: setup steps, an explicit receiving session, and
/// the status of every JPEG the camera sends.
struct PushTransferView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: PushTransferSession
    let cameraHost: String
    let onClose: () -> Void

    init(cameraHost: String, makeSession: @escaping @MainActor () -> PushTransferSession, onClose: @escaping () -> Void) {
        self.cameraHost = cameraHost
        self.onClose = onClose
        _session = StateObject(wrappedValue: makeSession())
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if session.needsPhotosAccess { photosAccessSection }
                if session.pendingFileCount > 0, !session.needsPhotosAccess { pendingSection }
                receivedSection
                setupSection
                discoverySection
            }
            .navigationTitle("Send While Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await session.stop()
                            onClose()
                        }
                    }
                    .accessibilityIdentifier("close-push-transfer")
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await session.setAppActive(false) }
            case .active: Task { await session.setAppActive(true) }
            default: break
            }
        }
        .onChange(of: session.phase.isActive) { _, isActive in
            // Keep the screen on while receiving: iOS stops the receiver when the iPhone locks.
            UIApplication.shared.isIdleTimerDisabled = isActive
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("push-transfer-status")

            if let network = session.joinableCameraNetwork {
                Button {
                    Task { await session.joinCameraNetwork() }
                } label: {
                    HStack {
                        Label("Join \(network)", systemImage: "wifi")
                        if session.networkJoin == .joining {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(session.networkJoin == .joining)
                .accessibilityIdentifier("join-camera-wifi")
                if case let .failed(message) = session.networkJoin {
                    Text("\(message) You can also join it in Settings and come straight back.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if session.savedCount > 0 {
                LabeledContent("Saved to Photos", value: "\(session.savedCount)")
                    .accessibilityIdentifier("push-transfer-saved-count")
            }

            if session.phase.isActive {
                Button("Stop receiving", role: .destructive) { Task { await session.stop() } }
                    .accessibilityIdentifier("stop-push-transfer")
            } else {
                Button {
                    Task { await session.start() }
                } label: {
                    Label("Start receiving", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-push-transfer")
            }
        } footer: {
            Text("Receiving works only while Retro LUMIX Sync is open, so the screen stays on. If the iPhone locks or you switch apps, receiving pauses until you return. A photo taken meanwhile is not sent: the camera shows “Connection error” and stops sending until you start its connection again. Those photos stay on the card and can be imported from the gallery.")
        }
    }

    private var photosAccessSection: some View {
        Section {
            Label("Photos access is needed to save received photos.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Received files are kept on this iPhone until they can be saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Button("Try saving again") { Task { await session.retryPendingSaves() } }
                .accessibilityIdentifier("retry-push-transfer-saves")
        }
    }

    private var pendingSection: some View {
        Section {
            Label("\(session.pendingFileCount) received \(session.pendingFileCount == 1 ? "photo is" : "photos are") waiting to be saved.",
                  systemImage: "tray.full")
            Button("Try saving again") { Task { await session.retryPendingSaves() } }
                .accessibilityIdentifier("retry-push-transfer-saves")
        }
    }

    private var receivedSection: some View {
        Section("Received") {
            if session.items.isEmpty {
                Text("Photos you take appear here as the camera sends them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.items) { item in
                PushTransferItemRow(item: item)
            }
        }
    }

    private var setupSection: some View {
        Section {
            step(1, "On the camera choose MENU → Wi‑Fi → Wi‑Fi Function → New Connection → Send Images While Recording → Smartphone.")
            step(2, "Choose Direct → Manual Connection. The camera shows its network name and password.")
            step(3, "Tap Start receiving, then Join the camera's network here, so Retro LUMIX Sync stays open while the camera looks for it. Without a Join button, join it in Settings and come straight back. If the camera shows “Connection failed”, start its connection again while this screen is open.")
            step(4, "When the camera lists “Retro LUMIX Sync”, select it. In the image settings choose Size → Original to receive full-size JPEGs, then press Set.")
            step(5, "Take photos. Each JPEG is saved to Photos after it arrives. RAW files are not sent.")
        } header: {
            Text("Set up the camera")
        } footer: {
            Text("The camera decides the size it sends. A received JPEG counts as the original only after the gallery compares it with the file on the card.")
        }
    }

    private var discoverySection: some View {
        Section("Discovery") {
            LabeledContent("Camera", value: cameraHost)
            LabeledContent("Camera's search", value: session.cameraSearched ? "Received" : "Not yet")
            if let endpoint = session.localEndpoint {
                LabeledContent("Receiver", value: endpoint)
                    .font(.caption.monospaced())
            }
            if let registration = session.registration, let label = registrationLabel(registration) {
                LabeledContent("Camera access", value: label)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Multicast sending: \(multicastLabel)").font(.subheadline)
                Text("Receiving does not need it. The camera's search reaches Retro LUMIX Sync, which answers the camera directly and also announces itself straight to the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("push-transfer-multicast-status")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.subheadline.monospacedDigit().bold()).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }

    // MARK: Labels

    private var statusTitle: String {
        switch session.phase {
        case .idle: return "Not receiving"
        case .waitingForCameraNetwork: return "Waiting for the camera's Wi‑Fi"
        case .starting: return "Starting…"
        case .advertising: return "Waiting for the camera"
        case .linked: return "Ready to receive"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .failed: return "Receiving failed"
        }
    }

    private var statusDetail: String {
        switch session.phase {
        case .idle: return "Follow the camera steps below, then start receiving."
        case .waitingForCameraNetwork where session.joinableCameraNetwork != nil:
            return "Join the camera's network here, so Retro LUMIX Sync stays open while the camera looks for it."
        case .waitingForCameraNetwork:
            return "Join the network the camera shows in Settings, then come straight back. Retro LUMIX Sync looks for the camera at \(cameraHost)."
        case .starting: return "Opening the receiver on this iPhone."
        case .advertising: return "Retro LUMIX Sync is announcing itself. Select it on the camera when it appears."
        case .linked where session.resumedAfterPause:
            return "Receiving again. If the camera shows “Connection error”, it tried to send while Retro LUMIX Sync was away: start its connection again."
        case .linked: return "The camera found Retro LUMIX Sync. Take a photo."
        case .paused: return "Retro LUMIX Sync is in the background. Return to the app to resume."
        case .stopped: return "The camera can no longer send to this iPhone until you start again."
        case let .failed(message): return message
        }
    }

    private var statusSymbol: String {
        switch session.phase {
        case .linked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .advertising, .starting, .waitingForCameraNetwork: return "antenna.radiowaves.left.and.right"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .linked: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .secondary
        }
    }

    private var multicastLabel: String {
        switch session.multicastStatus {
        case .unknown: return "not checked yet"
        case .available: return "available"
        case .blocked: return "blocked by iOS"
        }
    }

    /// The access request matters only on cameras that answer it; a GM1S refuses it
    /// (`err_non_support`, or no web server while sending) and receives photos anyway.
    private func registrationLabel(_ registration: PushTransferSession.RegistrationResult) -> String? {
        switch registration {
        case .accepted: return "Accepted"
        case .awaitingApprovalOnCamera: return "Accept on the camera"
        case .refused, .noReply: return nil
        }
    }
}

private struct PushTransferItemRow: View {
    let item: PushTransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.filename).font(.subheadline.weight(.semibold))
                Spacer()
                Label(stateLabel, systemImage: stateSymbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(stateColor)
            }
            if case let .receiving(bytes) = item.state, let total = item.declaredSize, total > 0 {
                ProgressView(value: Double(bytes), total: Double(total))
            }
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("push-transfer-item-\(item.filename)")
    }

    private var detail: String? {
        var parts: [String] = []
        if let width = item.pixelWidth, let height = item.pixelHeight { parts.append("\(width) × \(height)") }
        if let bytes = item.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if case let .failed(message) = item.state { parts.append(message) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stateLabel: String {
        switch item.state {
        case .announced: return "Announced"
        case let .receiving(bytes): return "Receiving \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        case .saving: return "Saving"
        case .saved: return "Saved to Photos"
        case .duplicate: return "Already saved"
        case .waitingForPhotosAccess: return "Waiting for Photos access"
        case .failed: return "Failed"
        }
    }

    private var stateSymbol: String {
        switch item.state {
        case .saved: return "checkmark.circle.fill"
        case .duplicate: return "equal.circle"
        case .failed: return "xmark.circle.fill"
        case .waitingForPhotosAccess: return "lock.circle"
        default: return "arrow.down.circle"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .saved: return .green
        case .failed: return .red
        case .waitingForPhotosAccess: return .orange
        default: return .secondary
        }
    }
}
