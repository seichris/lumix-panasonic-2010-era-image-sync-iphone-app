import SwiftUI
import UIKit

/// The iPhone viewfinder: live view, shutter, video, touch AF/shutter, zoom,
/// manual focus, and the settings the connected camera reports as available.
struct RemoteShootingView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: RemoteShootingSession
    @State private var visibleNotice: RemoteShootingNotice?

    init(makeSession: @escaping @MainActor () -> RemoteShootingSession) {
        _session = StateObject(wrappedValue: makeSession())
    }

    var body: some View {
        VStack(spacing: 10) {
            statusBar
            viewfinder
            exposureReadout
            settingsStrip
            Spacer(minLength: 0)
            controlDeck
        }
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle("Remote Shooting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay(alignment: .top) { noticeBanner }
        .task { await session.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await session.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await session.setAppActive(false) }
            case .active: Task { await session.setAppActive(true) }
            default: break
            }
        }
        .onChange(of: session.notice) { _, notice in
            guard let notice else { return }
            withAnimation { visibleNotice = notice }
            Task {
                try? await Task.sleep(for: .seconds(notice.style == .error ? 5 : 3))
                if visibleNotice?.id == notice.id { withAnimation { visibleNotice = nil } }
            }
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let battery = session.cameraState?.battery {
                Label("\(battery.level)/\(battery.maximum)", systemImage: batterySymbol(battery))
                    .accessibilityLabel("Battery \(battery.level) of \(battery.maximum)")
            }
            if let remaining = session.cameraState?.remainingPhotos {
                Label("\(remaining)", systemImage: "photo.stack")
                    .accessibilityLabel("\(remaining) photos remaining")
            }
            if session.isRecordingVideo {
                Label(recordingLabel, systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("remote-recording-indicator")
            }
            Spacer()
            if session.controls.exposureMode != .unknown {
                Text(session.controls.exposureMode.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.15), in: Capsule())
                    .accessibilityLabel("Mode dial \(session.controls.exposureMode.rawValue)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal)
        .frame(minHeight: 22)
    }

    private var recordingLabel: String {
        guard let seconds = session.cameraState?.videoProgressSeconds else { return "REC" }
        return String(format: "REC %d:%02d", seconds / 60, seconds % 60)
    }

    private func batterySymbol(_ battery: (level: Int, maximum: Int)) -> String {
        let fraction = Double(battery.level) / Double(battery.maximum)
        switch fraction {
        case ..<0.2: return "battery.0percent"
        case ..<0.45: return "battery.25percent"
        case ..<0.7: return "battery.50percent"
        case ..<0.95: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        GeometryReader { proxy in
            let imageSize = session.frame.map { CGSize(width: $0.image.width, height: $0.image.height) }
                ?? CGSize(width: 4, height: 3)
            let imageRect = Self.aspectFitRect(for: imageSize, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black
                // Only this layer observes the per-frame feed, so a new frame
                // redraws the picture without rebuilding menus elsewhere on screen.
                RemoteLiveFrameLayer(feed: session.feed, imageRect: imageRect, isLive: session.phase == .live)
                if let point = session.lastTouchPoint, session.phase == .live {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 2)
                        .frame(width: 44, height: 44)
                        .position(x: imageRect.minX + point.x * imageRect.width,
                                  y: imageRect.minY + point.y * imageRect.height)
                        .allowsHitTesting(false)
                }
                phaseOverlay
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard imageRect.contains(value.location), imageRect.width > 0, imageRect.height > 0 else { return }
                    let point = CGPoint(x: (value.location.x - imageRect.minX) / imageRect.width,
                                        y: (value.location.y - imageRect.minY) / imageRect.height)
                    Task { await session.touch(at: point) }
                }
            )
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-shooting-viewfinder")
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch session.phase {
        case .live:
            EmptyView()
        case .idle:
            overlayCard { ProgressView().tint(.white) }
        case let .connecting(message):
            overlayCard {
                ProgressView().tint(.white)
                Text(message)
            }
        case .awaitingCameraApproval:
            overlayCard {
                Image(systemName: "hand.raised")
                Text("Accept the connection on the camera.")
            }
        case let .paused(reason):
            overlayCard {
                Image(systemName: reason == .connectionLost ? "wifi.exclamationmark" : "pause.circle")
                Text(reason.message)
                if reason != .appInBackground {
                    Button("Retry now") { Task { await session.retry() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("remote-shooting-retry")
                }
            }
        case let .failed(message):
            overlayCard {
                Image(systemName: "exclamationmark.triangle")
                Text(message)
                Button("Try again") { Task { await session.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("remote-shooting-retry")
            }
        case .ended:
            overlayCard { Text("Remote shooting ended.") }
        }
    }

    private func overlayCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(16)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            .padding(24)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("remote-shooting-status")
    }

    static func aspectFitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Exposure and settings

    private var exposureReadout: some View {
        RemoteExposureReadout(
            feed: session.feed,
            shutter: session.controls.shutter?.currentLabel,
            aperture: session.controls.aperture?.currentLabel,
            iso: session.controls.settings.first { $0.kind == .iso }?.currentLabel
        )
    }

    private var settingsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let shutter = session.controls.shutter { exposureMenu(shutter, id: "shutter") }
                    if let aperture = session.controls.aperture { exposureMenu(aperture, id: "aperture") }
                    ForEach(session.controls.settings) { setting in
                        settingMenu(setting)
                    }
                }
                .padding(.horizontal)
            }
            if !session.controls.hasCameraMenus, !session.controls.settings.isEmpty {
                Text("This camera did not provide its settings menu, so settings are shown read-only.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal)
            }
        }
    }

    private func settingMenu(_ setting: RemoteShootingSetting) -> some View {
        Menu {
            ForEach(setting.options) { option in
                Button {
                    Task { await session.apply(option, to: setting) }
                } label: {
                    if setting.isCurrent(option) {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
                .disabled(!option.isEnabled)
            }
        } label: {
            settingChip(title: setting.title, value: setting.currentLabel, enabled: setting.canChange)
        }
        .disabled(!setting.canChange || !session.canOperate)
        .accessibilityIdentifier("remote-setting-\(setting.kind.rawValue)")
    }

    private func exposureMenu(_ control: RemoteExposureControl, id: String) -> some View {
        Menu {
            ForEach(control.options.reversed()) { option in
                Button {
                    Task { await session.apply(option, to: control) }
                } label: {
                    if control.isCurrent(option) {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            settingChip(title: control.title, value: control.currentLabel, enabled: control.isEnabled)
        }
        .disabled(!control.isEnabled || !session.canOperate)
        .accessibilityIdentifier("remote-setting-\(id)")
    }

    private func settingChip(title: String, value: String, enabled: Bool) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2)
            Text(value).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(enabled ? .white : .white.opacity(0.45))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(enabled ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Controls

    private var controlDeck: some View {
        VStack(spacing: 14) {
            if session.controls.isManualFocus { manualFocusControls }
            if session.controls.supportsPowerZoom, session.zoomUnavailableMessage == nil { zoomControls }
            if let message = session.zoomUnavailableMessage {
                Text(message).font(.caption2).foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .center) {
                Picker("Touch", selection: $session.touchMode) {
                    ForEach(RemoteTouchMode.allCases) { mode in
                        Text(mode == .focus ? "AF" : "Shutter").tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .accessibilityLabel("Touch action")
                .accessibilityIdentifier("remote-touch-mode")

                Spacer()
                shutterButton
                Spacer()

                Button {
                    Task { await session.toggleVideoRecording() }
                } label: {
                    Image(systemName: session.isRecordingVideo ? "stop.circle.fill" : "video.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red, .white.opacity(0.9))
                }
                .disabled(!session.canOperate)
                .frame(width: 130, alignment: .trailing)
                .accessibilityLabel(session.isRecordingVideo ? "Stop video" : "Record video")
                .accessibilityIdentifier("remote-video-button")
            }
            .padding(.horizontal)
        }
    }

    private var shutterButton: some View {
        ZStack {
            Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
            Circle()
                .fill(session.isShutterPressed ? Color.gray : Color.white)
                .frame(width: 62, height: 62)
            if session.isConfirmingCapture {
                ProgressView().tint(.black)
            }
        }
        .opacity(session.canOperate ? 1 : 0.4)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard session.canOperate, !session.isShutterPressed else { return }
                    Task { await session.pressShutter() }
                }
                .onEnded { _ in Task { await session.releaseShutter() } }
        )
        .accessibilityElement()
        .accessibilityLabel("Take photo")
        .accessibilityHint("Touch and hold for burst shooting")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await session.capturePhoto() } }
        .accessibilityIdentifier("remote-shutter-button")
    }

    private var zoomControls: some View {
        HStack(spacing: 24) {
            holdButton("W", systemImage: "minus.magnifyingglass", identifier: "remote-zoom-wide",
                       press: { await session.startZoom(.wide, fast: false) }, release: { await session.stopZoom() })
            Text("Zoom").font(.caption).foregroundStyle(.white.opacity(0.8))
            holdButton("T", systemImage: "plus.magnifyingglass", identifier: "remote-zoom-tele",
                       press: { await session.startZoom(.tele, fast: false) }, release: { await session.stopZoom() })
        }
    }

    private var manualFocusControls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 18) {
                holdButton("Near", systemImage: "chevron.backward.2", identifier: "remote-focus-near-fast",
                           press: { session.startFocusRepeat(.near, fast: true) }, release: { session.stopFocusRepeat() })
                holdButton("Near", systemImage: "chevron.backward", identifier: "remote-focus-near",
                           press: { session.startFocusRepeat(.near, fast: false) }, release: { session.stopFocusRepeat() })
                Text("MF").font(.caption.bold()).foregroundStyle(.white)
                holdButton("Far", systemImage: "chevron.forward", identifier: "remote-focus-far",
                           press: { session.startFocusRepeat(.far, fast: false) }, release: { session.stopFocusRepeat() })
                holdButton("Far", systemImage: "chevron.forward.2", identifier: "remote-focus-far-fast",
                           press: { session.startFocusRepeat(.far, fast: true) }, release: { session.stopFocusRepeat() })
            }
            if let position = session.focusPosition {
                ProgressView(value: position.fraction)
                    .tint(.yellow)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Focus position")
            }
        }
    }

    private func holdButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        press: @escaping @MainActor () async -> Void,
        release: @escaping @MainActor () async -> Void
    ) -> some View {
        HoldButton(title: title, systemImage: systemImage, isEnabled: session.canOperate, press: press, release: release)
            .accessibilityIdentifier(identifier)
    }

    // MARK: Notices

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = visibleNotice {
            Text(notice.message)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(noticeColor(notice.style).opacity(0.92), in: Capsule())
                .padding(.top, 6)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { withAnimation { visibleNotice = nil } }
                .accessibilityIdentifier("remote-shooting-notice")
        }
    }

    private func noticeColor(_ style: RemoteShootingNotice.Style) -> Color {
        switch style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// The live picture and the camera's AF frames, redrawn for every frame.
private struct RemoteLiveFrameLayer: View {
    @ObservedObject var feed: RemoteLiveViewFeed
    let imageRect: CGRect
    let isLive: Bool

    var body: some View {
        if let frame = feed.frame {
            Image(decorative: frame.image, scale: 1)
                .resizable()
                .frame(width: imageRect.width, height: imageRect.height)
                .offset(x: imageRect.minX, y: imageRect.minY)
                .opacity(isLive ? 1 : 0.45)
                .allowsHitTesting(false)
            ForEach(Array(frame.metadata.afFrames.enumerated()), id: \.offset) { _, af in
                let x0 = imageRect.minX + CGFloat(af.x0) / 1000 * imageRect.width
                let y0 = imageRect.minY + CGFloat(af.y0) / 1000 * imageRect.height
                let width = max(4, CGFloat(af.x1 - af.x0) / 1000 * imageRect.width)
                let height = max(4, CGFloat(af.y1 - af.y0) / 1000 * imageRect.height)
                Rectangle()
                    .stroke(Color(red: Double(af.red) / 255, green: Double(af.green) / 255, blue: Double(af.blue) / 255),
                            lineWidth: 2)
                    .frame(width: width, height: height)
                    .position(x: x0 + width / 2, y: y0 + height / 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Shutter, aperture, and exposure as the camera reports them in each frame,
/// falling back to the last values read with getsetting.
private struct RemoteExposureReadout: View {
    @ObservedObject var feed: RemoteLiveViewFeed
    let shutter: String?
    let aperture: String?
    let iso: String?

    var body: some View {
        let exposure = feed.frame?.metadata.exposure
        HStack(spacing: 18) {
            Text(exposure?.shutterLabel ?? shutter ?? "–")
            Text(exposure?.apertureLabel ?? aperture ?? "–")
            Text(exposure?.exposureLabel ?? "±0")
            if let iso { Text("ISO \(iso)") }
        }
        .font(.callout.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("remote-exposure-readout")
    }
}

/// A button that reports touch-down and touch-up, for zoom and manual focus.
private struct HoldButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let press: @MainActor () async -> Void
    let release: @MainActor () async -> Void
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 40)
            .background(.white.opacity(isPressed ? 0.35 : 0.16), in: RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !isPressed else { return }
                        isPressed = true
                        Task { await press() }
                    }
                    .onEnded { _ in
                        guard isPressed else { return }
                        isPressed = false
                        Task { await release() }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                Task {
                    await press()
                    try? await Task.sleep(for: .milliseconds(300))
                    await release()
                }
            }
    }
}
