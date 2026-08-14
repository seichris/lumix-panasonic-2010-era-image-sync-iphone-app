import SwiftUI
import UIKit

struct CameraGalleryView: View {
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var isSelecting = false
    @State private var importMode: CameraPhotoImportMode = .jpeg
    @State private var showNoNewMediaAlert = false

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
                    Button("Retry") { Task { await store.loadInitial() } }
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
            if store.phase == .idle { await store.loadInitial() }
        }
        .onDisappear { store.cancelLoading() }
        .onChange(of: store.selectedPhotoIDs) { _, _ in
            let modes = selectedPhotoImportModes
            if !modes.isEmpty, !modes.contains(importMode) {
                importMode = modes.first ?? .jpeg
            }
        }
        .navigationDestination(for: LumixPhoto.self) { photo in
            CameraPhotoDetailView(photo: photo, store: store, model: model)
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
                    ForEach(store.photos) { photo in
                        galleryCell(photo)
                            .onAppear {
                                guard photo.id == store.photos.suffix(5).first?.id else { return }
                                Task { await store.loadNextPage() }
                            }
                    }
                }

                paginationFooter
            }
            .padding(.bottom, 12)
        }
        .refreshable { await store.loadInitial() }
        .accessibilityIdentifier("camera-gallery")
    }

    private var gallerySummary: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Image App Direct", systemImage: "wifi")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                Text("\(store.photos.count) of \(store.totalCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("camera-gallery-count")
            }

            if let progress = store.batchProgress, progress.completed > 0 || store.isImporting {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: progress.fractionCompleted)
                    HStack {
                        Text(store.isImporting ? "Importing \(progress.currentTitle ?? "item")" : "Import complete")
                        Spacer()
                        Text("\(progress.saved) saved · \(progress.failed) failed")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("batch-import-progress")
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
        } else {
            Text("All \(store.photos.count) camera items loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .accessibilityIdentifier("all-camera-items-loaded")
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
                Button("Select newest 10") {
                    isSelecting = true
                    store.selectNewest(10)
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
                            .font(.caption)
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
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .background(.white, in: Circle())
        }
    }

    private var importAccessibilityValue: String {
        switch importState {
        case .downloading: return "Downloading"
        case .saving: return "Saving"
        case .saved: return historyAccessibilityValue
        case .failed: return "Import failed"
        case nil: return historyAccessibilityValue
        }
    }

    private var historyAccessibilityValue: String {
        guard let historyRecord else { return "Not imported by GM1 Sync" }
        return "Previously imported: \(historyRecord.summary)"
    }
}

private struct CameraPhotoDetailView: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var importMode: CameraPhotoImportMode = .jpeg

    private var importState: CameraPhotoImportState? { store.importStates[photo.id] }
    private var historyRecord: CameraImportHistoryRecord? { store.importHistoryRecord(for: photo) }
    private var availablePhotoModes: [CameraPhotoImportMode] {
        CameraPhotoImportMode.allCases.filter(photo.supports)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CameraMediaImage(
                    resource: photo.previewResource,
                    placeholderSystemImage: photo.kind == .video ? "video" : "photo"
                ) { resource in
                    try await store.mediaData(for: resource)
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 7) {
                    Text(photo.title).font(.title3.bold())
                    if let itemID = photo.itemID {
                        LabeledContent("Camera item", value: itemID)
                    }
                    if photo.kind == .video {
                        LabeledContent("Original video") {
                            Text(photo.videoResource?.url.pathExtension.uppercased() ?? "Unavailable")
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
                        if model.locationLogger.samples.isEmpty {
                            Label("No saved location samples", systemImage: "location.slash")
                                .foregroundStyle(.secondary)
                        } else {
                            Label(
                                "\(model.locationLogger.samples.count) location \(model.locationLogger.samples.count == 1 ? "sample" : "samples") available",
                                systemImage: "location.fill"
                            )
                            .foregroundStyle(.green)
                        }
                        Text("The original's EXIF time is matched during import. If no nearby track point exists, the unchanged original is saved without a location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                importStatus

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
                .disabled(!photo.isImportable || !photo.supports(importMode) || store.isImporting || importState?.isWorking == true)
                .accessibilityIdentifier("save-camera-photo")
            }
            .padding()
        }
        .navigationTitle(photo.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !availablePhotoModes.isEmpty, !availablePhotoModes.contains(importMode) {
                importMode = availablePhotoModes.first ?? .jpeg
            }
        }
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
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case nil:
            EmptyView()
        }
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
                    .scaledToFill()
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
