#if os(iOS)
import MapKit
import SwiftUI

struct ManualLocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CameraGalleryStore
    let photos: [LumixPhoto]

    @State private var query = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var selectedResultIndex: Int?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearch: MKLocalSearch?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                if isSearching {
                    ProgressView("Searching Apple Maps…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }

                Map(position: $cameraPosition) {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { index, item in
                        Marker(
                            item.name ?? "Location",
                            coordinate: item.placemark.coordinate
                        )
                        .tint(index == selectedResultIndex ? .blue : .red)
                    }
                }
                .frame(height: 280)
                .accessibilityIdentifier("manual-location-map")

                if let searchError {
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { index, item in
                            Button {
                                selectResult(at: index)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: index == selectedResultIndex
                                        ? "checkmark.circle.fill"
                                        : "mappin.circle")
                                        .foregroundStyle(index == selectedResultIndex ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name ?? "Location")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        if let address = address(for: item) {
                                            Text(address)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal)
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("manual-location-result-\(index)")
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    if let selectedItem {
                        Label(
                            "Selected: \(selectedItem.name ?? "Location")",
                            systemImage: "mappin.and.ellipse"
                        )
                        .font(.subheadline.weight(.semibold))
                        if let address = address(for: selectedItem) {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Search for a place, then choose a result to set the location for all \(photos.count) selected images.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Use this location") {
                        confirmSelection()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(selectedItem == nil || isSearching)
                    .accessibilityIdentifier("confirm-manual-location")
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Set Image Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .alert(
            "Could not save location",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The location could not be saved.")
        }
        .onDisappear {
            searchTask?.cancel()
            activeSearch?.cancel()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search for a place or address", text: $query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("manual-location-search")
                .onSubmit(search)
            Button {
                search()
            } label: {
                Image(systemName: "arrow.right.circle.fill")
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            .accessibilityLabel("Search map")
            .accessibilityIdentifier("manual-location-search-button")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var selectedItem: MKMapItem? {
        guard let selectedResultIndex,
              searchResults.indices.contains(selectedResultIndex) else { return nil }
        return searchResults[selectedResultIndex]
    }

    private func search() {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        searchTask?.cancel()
        activeSearch?.cancel()
        selectedResultIndex = nil
        searchError = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        if let region = cameraPosition.region {
            request.region = region
        }
        let search = MKLocalSearch(request: request)
        activeSearch = search
        isSearching = true

        searchTask = Task { @MainActor in
            do {
                let response = try await search.start()
                guard !Task.isCancelled, activeSearch === search else { return }
                searchResults = response.mapItems
                if searchResults.isEmpty {
                    searchError = "No matching places were found. Try a nearby address or landmark."
                } else {
                    selectResult(at: 0)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, activeSearch === search else { return }
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func selectResult(at index: Int) {
        guard searchResults.indices.contains(index) else { return }
        selectedResultIndex = index
        let coordinate = searchResults[index].placemark.coordinate
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        )
    }

    private func confirmSelection() {
        guard let selectedItem else { return }
        let coordinate = selectedItem.placemark.coordinate
        let location = PhotoGeotagLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )

        do {
            try store.setManualLocation(location, for: photos)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func address(for item: MKMapItem) -> String? {
        guard let title = item.placemark.title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }
}
#endif
