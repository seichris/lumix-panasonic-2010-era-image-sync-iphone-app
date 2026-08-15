import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct CameraGalleryView: View {
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var isSelecting = false
    @State private var importMode: CameraPhotoImportMode = .jpeg
    @State private var showNoNewMediaAlert = false
    @State private var showFailedOnly = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView("Loading camera media…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("camera-gallery-loading")

            case .empty:
                ContentUnavailableView(
                    "No media on the camera",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Take a photo or video, or check that the SD card is inserted, then refresh.")
                )

            case let .failed(message):
                ContentUnavailableView {
                    Label("Camera browser unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await store.reloadAllMedia() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("retry-camera-gallery")
                }

            case .loaded:
                gallery
            }
        }
        .navigationTitle("Camera Media")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { galleryToolbar }
        .safeAreaInset(edge: .bottom) {
            if isSelecting || store.isImporting { importBar }
        }
        .task {
            if store.phase == .idle {
                await store.reloadAllMedia()
            } else if store.canLoadMore {
                await store.loadAllPages()
            }
        }
        .onDisappear { store.cancelLoading() }
        .onChange(of: store.selectedPhotoIDs) { _, _ in
            let modes = selectedPhotoImportModes
            if !modes.isEmpty, !modes.contains(importMode) {
                importMode = modes.first ?? .jpeg
            }
        }
        .onChange(of: store.failedPhotos.count) { _, failedCount in
            if failedCount == 0 { showFailedOnly = false }
        }
        .navigationDestination(for: LumixPhoto.self) { photo in
            CameraPhotoDetailPager(initialPhoto: photo, store: store, model: model)
        }
        .alert("No new camera media", isPresented: $showNoNewMediaAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Everything currently advertised by this camera has already been imported by GM1 Sync.")
        }
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                gallerySummary

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(visibleMedia) { photo in
                        galleryCell(photo)
                    }
                }

                paginationFooter
            }
            .padding(.bottom, 12)
        }
        .refreshable { await store.reloadAllMedia() }
        .accessibilityIdentifier("camera-gallery")
    }

    private var gallerySummary: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Image App Direct", systemImage: "wifi")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text(mediaCountText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("camera-gallery-count")
            }

            if let progress = store.batchProgress, progress.completed > 0 || store.isImporting {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress.fractionCompleted)
                    HStack(alignment: .firstTextBaseline) {
                        Text(store.isImporting ? "Importing \(progress.currentTitle ?? "item")" : "Import complete")
                        Spacer()
                        HStack(spacing: 0) {
                            Text("\(progress.attempted) attempted · \(progress.saved) saved · ")
                            if progress.failed > 0 {
                                Button("\(progress.failed) failed") {
                                    showFailedOnly = true
                                    isSelecting = false
                                    store.clearSelection()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .accessibilityHint("Shows only the files that failed to import")
                                .accessibilityIdentifier("show-failed-imports")
                            } else {
                                Text("0 failed")
                            }
                        }
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("batch-import-progress")
            }

            if showFailedOnly {
                HStack {
                    Label(
                        "Showing \(store.failedPhotos.count) failed \(store.failedPhotos.count == 1 ? "import" : "imports")",
                        systemImage: "xmark.circle.fill"
                    )
                    .foregroundStyle(.red)
                    Spacer()
                    Button("Show all") { showFailedOnly = false }
                        .accessibilityIdentifier("show-all-camera-media")
                }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("failed-import-filter")
            }

            if !store.importHistory.isEmpty {
                Text("Green checks mark media imported by GM1 Sync on this iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
    }

    private var visibleMedia: [LumixPhoto] {
        showFailedOnly ? store.failedPhotos : store.photos
    }

    private var mediaCountText: String {
        if store.hasCompleteMediaCounts {
            return "\(store.imageCount) images · \(store.videoCount) videos"
        }
        if store.paginationError != nil {
            return "Media count unavailable"
        }
        return "Scanning \(store.totalCount) camera items…"
    }

    @ViewBuilder
    private func galleryCell(_ photo: LumixPhoto) -> some View {
        if isSelecting {
            Button { store.toggleSelection(photo) } label: {
                CameraPhotoGridCell(
                    photo: photo,
                    store: store,
                    isSelected: store.selectedPhotoIDs.contains(photo.id),
                    importState: store.importStates[photo.id],
                    historyRecord: store.importHistoryRecord(for: photo)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("select-camera-photo-\(photo.id)")
        } else {
            NavigationLink(value: photo) {
                CameraPhotoGridCell(
                    photo: photo,
                    store: store,
                    isSelected: false,
                    importState: store.importStates[photo.id],
                    historyRecord: store.importHistoryRecord(for: photo)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-camera-photo-\(photo.id)")
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if store.isLoadingNextPage {
            ProgressView("Loading more…")
                .padding()
        } else if let error = store.paginationError {
            VStack(spacing: 8) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry older media") { Task { await store.loadNextPage() } }
                    .buttonStyle(.bordered)
            }
            .padding()
        } else if store.canLoadMore {
            Button("Load older media") { Task { await store.loadNextPage() } }
                .buttonStyle(.bordered)
                .padding()
        }
    }

    @ToolbarContentBuilder
    private var galleryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting { store.clearSelection() }
            }
            .disabled(store.phase != .loaded || store.isImporting)
            .accessibilityIdentifier("toggle-photo-selection")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Load all media") { Task { await store.loadAllPages() } }
                    .disabled(!store.canLoadMore)
                Button("Import new only") {
                    Task {
                        await store.loadAllPages()
                        let selectedCount = store.selectUnimported()
                        isSelecting = selectedCount > 0
                        showNoNewMediaAlert = selectedCount == 0 && store.paginationError == nil
                    }
                }
                .disabled(store.photos.isEmpty || store.isImporting)
                Button("Select all items") {
                    Task {
                        await store.loadAllPages()
                        store.selectAll()
                        isSelecting = !store.selectedPhotoIDs.isEmpty
                    }
                }
                .disabled(store.photos.isEmpty || store.isImporting)
            } label: {
                Label("Gallery actions", systemImage: "ellipsis.circle")
            }
        }
    }

    private var importBar: some View {
        VStack(spacing: 8) {
            if store.isImporting, let progress = store.batchProgress {
                ProgressView(value: progress.fractionCompleted)
            }

            if !selectedPhotoImportModes.isEmpty {
                Picker("Photo format", selection: $importMode) {
                    ForEach(selectedPhotoImportModes) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.isImporting)
                .accessibilityIdentifier("camera-import-format")
            }

            if !store.selectedPhotoIDs.isEmpty {
                Text("Review the selected new items, choose a photo format, then confirm the import.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text(store.isImporting ? "Importing originals…" : "\(store.selectedPhotoIDs.count) selected")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Import to Photos") {
                    Task {
                        await store.importSelected(
                            photoMode: importMode,
                            samples: model.locationLogger.samples,
                            cameraClockOffset: model.cameraClockOffsetMinutes * 60
                        )
                        if store.selectedPhotoIDs.isEmpty { isSelecting = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canImportSelected(using: importMode) || store.isImporting)
                .accessibilityIdentifier("import-selected-photos")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectedPhotoImportModes: [CameraPhotoImportMode] {
        let selectedPhotos = store.selectedPhotos.filter { $0.kind == .photo }
        guard !selectedPhotos.isEmpty else { return [] }
        return CameraPhotoImportMode.allCases.filter { mode in
            selectedPhotos.allSatisfy { $0.supports(mode) }
        }
    }
}

private struct CameraPhotoGridCell: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    let isSelected: Bool
    let importState: CameraPhotoImportState?
    let historyRecord: CameraImportHistoryRecord?

    var body: some View {
        ZStack {
            ZStack {
                Color.secondary.opacity(0.12)
                CameraMediaImage(
                    resource: photo.thumbnailResource,
                    placeholderSystemImage: photo.kind == .video ? "video" : "photo"
                ) { resource in
                    try await store.mediaData(for: resource)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipped()

            if case let .failed(failure) = importState {
                Color.red.opacity(0.2)
                Rectangle()
                    .stroke(Color.red, lineWidth: 3)
                VStack {
                    Spacer()
                    Text(failure.filename)
                        .font(.caption2.weight(.bold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.9))
                }
            }

            VStack {
                HStack {
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                    } else if let importState, importState != .saved {
                        importBadge(importState)
                    }
                }
                Spacer()
                HStack {
                    if photo.kind == .video {
                        Image(systemName: "video.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .padding(6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    Spacer()
                    if historyRecord != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .background(.white, in: Circle())
                    }
                }
            }
            .padding(6)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.title)
        .accessibilityValue(isSelected ? "Selected" : importAccessibilityValue)
    }

    @ViewBuilder
    private func importBadge(_ state: CameraPhotoImportState) -> some View {
        switch state {
        case .downloading, .saving:
            ProgressView()
                .controlSize(.small)
                .padding(5)
                .background(.regularMaterial, in: Circle())
        case .saved:
            EmptyView()
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .background(.white, in: Circle())
        }
    }

    private var importAccessibilityValue: String {
        switch importState {
        case .downloading: return "Downloading"
        case .saving: return "Saving"
        case .saved: return historyAccessibilityValue
        case let .failed(failure): return "Import failed: \(failure.filename)"
        case nil: return historyAccessibilityValue
        }
    }

    private var historyAccessibilityValue: String {
        guard let historyRecord else { return "Not imported by GM1 Sync" }
        return "Previously imported: \(historyRecord.summary)"
    }
}

private struct CameraPhotoDetailPager: View {
    let initialPhoto: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var selectedPhotoID: LumixPhoto.ID

    init(initialPhoto: LumixPhoto, store: CameraGalleryStore, model: ProbeViewModel) {
        self.initialPhoto = initialPhoto
        self.store = store
        self.model = model
        _selectedPhotoID = State(initialValue: initialPhoto.id)
    }

    private var photos: [LumixPhoto] {
        store.photos.isEmpty ? [initialPhoto] : store.photos
    }

    private var selectedPhoto: LumixPhoto {
        photos.first(where: { $0.id == selectedPhotoID }) ?? initialPhoto
    }

    var body: some View {
        TabView(selection: $selectedPhotoID) {
            ForEach(photos) { photo in
                CameraPhotoDetailPage(photo: photo, store: store, model: model)
                    .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle(selectedPhoto.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("camera-media-detail-pager")
    }
}

private struct CameraPhotoDetailPage: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var importMode: CameraPhotoImportMode = .jpeg

    private var importState: CameraPhotoImportState? { store.importStates[photo.id] }
    private var historyRecord: CameraImportHistoryRecord? { store.importHistoryRecord(for: photo) }
    private var availablePhotoModes: [CameraPhotoImportMode] {
        CameraPhotoImportMode.allCases.filter(photo.supports)
    }
    private var previewGeotagMatch: GeotagMatch? {
        guard let captureDate = photo.captureDate else { return nil }
        return LocationTrackMatcher.match(
            captureDate: captureDate,
            samples: model.locationLogger.samples,
            cameraClockOffset: model.cameraClockOffsetMinutes * 60
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if photo.kind == .video {
                    if isAVCHDVideo {
                        CameraAVCHDUnavailablePreview(photo: photo, store: store)
                    } else {
                        CameraVideoPreview(photo: photo, store: store)
                    }
                } else {
                    CameraMediaImage(
                        resource: photo.previewResource,
                        placeholderSystemImage: "photo",
                        contentMode: .fit
                    ) { resource in
                        try await store.mediaData(for: resource)
                    }
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(photo.title).font(.title3.bold())
                    if let itemID = photo.itemID {
                        LabeledContent("Camera item", value: itemID)
                    }
                    if photo.kind == .video {
                        LabeledContent("Original video") {
                            Text(photo.videoResource?.downloadURL.lastPathComponent ?? "Unavailable")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        LabeledContent("Original JPEG") {
                            Text(photo.originalJPEGResource?.profileName ?? "Unavailable")
                        }
                        LabeledContent("Original RAW") {
                            Text(photo.rawResource?.url.pathExtension.uppercased() ?? "Unavailable")
                        }
                    }
                    if let historyRecord {
                        LabeledContent("Previously imported", value: historyRecord.summary)
                            .foregroundStyle(.green)
                    }
                }

                if photo.kind == .photo {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Import format").font(.headline)
                        Picker("Import format", selection: $importMode) {
                            ForEach(availablePhotoModes) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("detail-camera-import-format")

                        Text("JPEG is the default. JPEG + RAW stays together as one Photos asset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Geotagging").font(.headline)
                        if let match = previewGeotagMatch {
                            MatchedLocationMap(match: match)
                            Label("Location match available", systemImage: "mappin.circle.fill")
                                .foregroundStyle(.green)
                            LabeledContent("Camera listing time") {
                                Text(match.captureDate.formatted(date: .abbreviated, time: .standard))
                            }
                            LabeledContent("Position") {
                                Text(String(format: "%.5f, %.5f", match.latitude, match.longitude))
                                    .font(.caption.monospaced())
                            }
                            Text("This is a preview based on the time advertised by the camera. Import confirms the match using the original JPEG's EXIF capture time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if model.locationLogger.samples.isEmpty {
                            Label("No GPS track points recorded", systemImage: "location.slash")
                                .foregroundStyle(.secondary)
                            Text("No location can be matched to this image until the location log contains a nearby track point.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let captureDate = photo.captureDate {
                            Label("No nearby location match", systemImage: "location.slash")
                                .foregroundStyle(.orange)
                            LabeledContent("Camera listing time") {
                                Text(captureDate.formatted(date: .abbreviated, time: .standard))
                            }
                            Text("The camera supplied a capture time, but none of the recorded GPS track points are within 15 minutes. Import will verify this using the JPEG's EXIF time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Download required to verify", systemImage: "arrow.down.circle")
                                .foregroundStyle(.orange)
                            Text("\(model.locationLogger.samples.count) GPS track \(model.locationLogger.samples.count == 1 ? "point is" : "points are") recorded, but this camera item has no trustworthy capture time. Import must read the original JPEG's EXIF time before it can determine a match.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                importStatus

                if isAVCHDVideo {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("AVCHD unavailable", systemImage: "video.slash")
                            .font(.headline)
                        Text("This camera does not make AVCHD videos available for playback or import over Wi-Fi. Record MP4 to play and import videos on iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("camera-avchd-unavailable")
                } else if store.canImport(photo, using: importMode) {
                    Button {
                        Task {
                            await store.importPhoto(
                                photo,
                                photoMode: importMode,
                                samples: model.locationLogger.samples,
                                cameraClockOffset: model.cameraClockOffsetMinutes * 60
                            )
                        }
                    } label: {
                        Label(importButtonTitle, systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isImporting || importState?.isWorking == true)
                    .accessibilityIdentifier("save-camera-photo")
                } else if photo.kind == .video {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Playback only", systemImage: "play.rectangle.on.rectangle")
                            .font(.headline)
                        Text("This camera does not permit this video to be copied to iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("camera-video-playback-only")
                }
            }
            .padding()
        }
        .accessibilityIdentifier("camera-media-detail-\(photo.id)")
        .task {
            if !availablePhotoModes.isEmpty, !availablePhotoModes.contains(importMode) {
                importMode = availablePhotoModes.first ?? .jpeg
            }
        }
    }

    private var isAVCHDVideo: Bool {
        photo.kind == .video && photo.videoPlaybackResource?.isAVCHD == true
    }

    private var importButtonTitle: String {
        let again = historyRecord != nil || importState == .saved
        if photo.kind == .video {
            return again ? "Import video again" : "Import video to Photos"
        }
        return again ? "Import \(importMode.title) again" : "Import \(importMode.title) to Photos"
    }

    @ViewBuilder
    private var importStatus: some View {
        switch importState {
        case .downloading:
            Label("Downloading the untouched original…", systemImage: "arrow.down.circle")
        case .saving:
            Label("Adding the original to Photos…", systemImage: "photo.badge.arrow.down")
        case .saved:
            Label("Imported to Photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 4) {
                Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(failure.filename)
                    .font(.caption.weight(.semibold))
                Text(failure.message).font(.caption).foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
    }
}

private struct CameraAVCHDUnavailablePreview: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore

    var body: some View {
        ZStack {
            Color.black
            CameraMediaImage(
                resource: photo.previewResource,
                placeholderSystemImage: "video",
                contentMode: .fit
            ) { resource in
                try await store.mediaData(for: resource)
            }

            Label("AVCHD unavailable", systemImage: "video.slash.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("camera-avchd-preview-unavailable")
    }
}

private struct CameraVideoPreview: View {
    private struct ActivePlayback {
        let id: UUID
        let session: any CameraPlaybackSession
    }

    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    @State private var playbackRequest = 0
    @State private var isLoading = false
    @State private var loadingMessage = "Connecting to camera…"
    @State private var player: AVPlayer?
    @State private var activePlayback: ActivePlayback?
    @State private var errorMessage: String?
    @State private var diagnosticReport: String?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
            } else {
                CameraMediaImage(
                    resource: photo.previewResource,
                    placeholderSystemImage: "video",
                    contentMode: .fit
                ) { resource in
                    try await store.mediaData(for: resource)
                }

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text(loadingMessage)
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Button {
                        playbackRequest += 1
                    } label: {
                        Label(
                            errorMessage == nil ? "Play video" : "Try playback again",
                            systemImage: "play.circle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.7), in: Capsule())
                    }
                    .accessibilityIdentifier("play-camera-video")
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottom) {
            if let errorMessage {
                VStack(spacing: 6) {
                    Text(errorMessage)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    if let diagnosticReport {
                        Button {
                            UIPasteboard.general.string = diagnosticReport
                        } label: {
                            Label("Copy playback diagnostics", systemImage: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityIdentifier("copy-playback-diagnostics")
                    }
                }
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.9))
            }
        }
        .task(id: playbackRequest) {
            guard playbackRequest > 0 else { return }
            await loadAndPlay()
        }
        .onDisappear { cleanUpPlayback() }
    }

    @MainActor
    private func loadAndPlay() async {
        player?.pause()
        player = nil
        errorMessage = nil
        diagnosticReport = nil
        isLoading = true
        loadingMessage = photo.videoPlaybackResource?.isAVCHD == true
            ? "Connecting to camera…"
            : "Downloading video…"
        await stopActivePlayback()

        var startedPlayback: ActivePlayback?
        do {
            let session = try await store.videoPlaybackSession(photo)
            let playback = ActivePlayback(id: UUID(), session: session)
            startedPlayback = playback
            activePlayback = playback
            let playbackURL = try await session.start()
            try Task.checkCancellation()

            loadingMessage = "Buffering…"
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(url: playbackURL))
            player = newPlayer
            isLoading = false
            newPlayer.play()
        } catch is CancellationError {
            isLoading = false
            if let startedPlayback {
                await startedPlayback.session.stop()
                if activePlayback?.id == startedPlayback.id { activePlayback = nil }
            }
        } catch {
            isLoading = false
            let diagnostics = await startedPlayback?.session.diagnostics()
            errorMessage = diagnostics?.failureSummary ?? error.localizedDescription
            diagnosticReport = diagnostics?.report
            if let startedPlayback {
                await startedPlayback.session.stop()
                if activePlayback?.id == startedPlayback.id { activePlayback = nil }
            }
        }
    }

    @MainActor
    private func cleanUpPlayback() {
        player?.pause()
        player = nil
        isLoading = false
        let playback = activePlayback
        activePlayback = nil
        Task { await playback?.session.stop() }
    }

    @MainActor
    private func stopActivePlayback() async {
        let playback = activePlayback
        activePlayback = nil
        await playback?.session.stop()
    }
}

private struct CameraMediaImage: View {
    private enum Phase {
        case idle
        case loading
        case image(UIImage)
        case failed
    }

    let resource: LumixResource?
    var placeholderSystemImage = "photo"
    var contentMode: ContentMode = .fill
    let load: (LumixResource) async throws -> Data
    @State private var phase: Phase = .idle

    var body: some View {
        ZStack {
            switch phase {
            case .idle, .loading:
                ProgressView()
            case let .image(image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .failed:
                Image(systemName: placeholderSystemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: resource?.id) {
            guard let resource else {
                phase = .failed
                return
            }
            phase = .loading
            do {
                let data = try await load(resource)
                try Task.checkCancellation()
                guard let image = UIImage(data: data) else {
                    phase = .failed
                    return
                }
                phase = .image(image)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed
            }
        }
    }
}

#Preview("Connected gallery") {
    NavigationStack {
        CameraGalleryView(
            store: CameraGalleryStore(
                previewPhase: .loaded,
                photos: DemoCameraGalleryClient.photos(12),
                totalCount: 12
            ),
            model: ProbeViewModel()
        )
    }
}

#Preview("Loading gallery") {
    NavigationStack {
        CameraGalleryView(
            store: CameraGalleryStore(previewPhase: .loading),
            model: ProbeViewModel()
        )
    }
}

#Preview("Empty gallery") {
    NavigationStack {
        CameraGalleryView(
            store: CameraGalleryStore(previewPhase: .empty),
            model: ProbeViewModel()
        )
    }
}

#Preview("Gallery error") {
    NavigationStack {
        CameraGalleryView(
            store: CameraGalleryStore(previewPhase: .failed("The camera went to sleep.")),
            model: ProbeViewModel()
        )
    }
}
