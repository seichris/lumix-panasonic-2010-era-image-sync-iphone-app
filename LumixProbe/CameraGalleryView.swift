import SwiftUI
import UIKit

struct CameraGalleryView: View {
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel
    @State private var isSelecting = false

    private let columns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                ProgressView("Loading camera photos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("camera-gallery-loading")

            case .empty:
                ContentUnavailableView(
                    "No photos on the camera",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Take a photo or check that the SD card is inserted, then refresh.")
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
        .navigationTitle("Camera Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { galleryToolbar }
        .safeAreaInset(edge: .bottom) {
            if isSelecting || store.isImporting { importBar }
        }
        .task {
            if store.phase == .idle { await store.loadInitial() }
        }
        .onDisappear { store.cancelLoading() }
        .navigationDestination(for: LumixPhoto.self) { photo in
            CameraPhotoDetailView(photo: photo, store: store, model: model)
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
                        Text(store.isImporting ? "Importing \(progress.currentTitle ?? "photo")" : "Import complete")
                        Spacer()
                        Text("\(progress.saved) saved · \(progress.failed) failed")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("batch-import-progress")
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
                    importState: store.importStates[photo.id]
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
                    importState: store.importStates[photo.id]
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
                Button("Retry older photos") { Task { await store.loadNextPage() } }
                    .buttonStyle(.bordered)
            }
            .padding()
        } else if store.canLoadMore {
            Button("Load older photos") { Task { await store.loadNextPage() } }
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
                Button("Load all photos") { Task { await store.loadAllPages() } }
                    .disabled(!store.canLoadMore)
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

            HStack {
                Text(store.isImporting ? "Importing originals…" : "\(store.selectedPhotoIDs.count) selected")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Import to Photos") {
                    Task {
                        await store.importSelected(
                            samples: model.locationLogger.samples,
                            cameraClockOffset: model.cameraClockOffsetMinutes * 60
                        )
                        if store.selectedPhotoIDs.isEmpty { isSelecting = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.selectedPhotoIDs.isEmpty || store.isImporting)
                .accessibilityIdentifier("import-selected-photos")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct CameraPhotoGridCell: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    let isSelected: Bool
    let importState: CameraPhotoImportState?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.secondary.opacity(0.12)
                CameraMediaImage(resource: photo.thumbnailResource) { resource in
                    try await store.mediaData(for: resource)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipped()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)
                    .padding(6)
            } else if let importState {
                importBadge(importState)
                    .padding(6)
            }
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
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
                .background(.white, in: Circle())
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
        case .saved: return "Saved"
        case .failed: return "Import failed"
        case nil: return "Not selected"
        }
    }
}

private struct CameraPhotoDetailView: View {
    let photo: LumixPhoto
    @ObservedObject var store: CameraGalleryStore
    @ObservedObject var model: ProbeViewModel

    private var importState: CameraPhotoImportState? { store.importStates[photo.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CameraMediaImage(resource: photo.previewResource) { resource in
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
                    LabeledContent("Original JPEG") {
                        Text(photo.originalJPEGResource?.profileName ?? "Unavailable")
                    }
                    if photo.rawResource != nil {
                        Label("RAW companion available for future export", systemImage: "doc.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

                importStatus

                Button {
                    Task {
                        await store.importPhoto(
                            photo,
                            samples: model.locationLogger.samples,
                            cameraClockOffset: model.cameraClockOffsetMinutes * 60
                        )
                    }
                } label: {
                    Label(importState == .saved ? "Save another copy" : "Save original to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(photo.originalJPEGResource == nil || store.isImporting || importState?.isWorking == true)
                .accessibilityIdentifier("save-camera-photo")
            }
            .padding()
        }
        .navigationTitle(photo.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var importStatus: some View {
        switch importState {
        case .downloading:
            Label("Downloading the untouched original…", systemImage: "arrow.down.circle")
        case .saving:
            Label("Adding the original to Photos…", systemImage: "photo.badge.arrow.down")
        case .saved:
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
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
                Image(systemName: "photo")
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
