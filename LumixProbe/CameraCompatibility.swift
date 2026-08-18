import SwiftUI

struct CameraCompatibilityView: View {
    var body: some View {
        List {
            Section {
                Text("GM1 Sync is being validated on the GM family first. The other cameras are candidates because Panasonic lists them in the same Image App ecosystem; inclusion does not mean compatibility has been confirmed.")
                    .font(.subheadline)
            }

            ForEach(CameraCompatibilityCatalog.sections) { section in
                Section {
                    ForEach(section.cameras) { camera in
                        CameraCandidateRow(camera: camera)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    Text(section.detail)
                }
            }

            Section("About this list") {
                Text("Dates are approximate model-introduction eras based on Panasonic's Image App support history, not exact manufacturing spans.")
                Text("Panasonic, LUMIX, and the camera model names belong to their respective owner. GM1 Sync is independent software and is not affiliated with or endorsed by Panasonic.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Camera candidates")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }
}

private struct CameraCandidateRow: View {
    let camera: CameraCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(camera.models)
                .font(.headline)
            HStack(spacing: 8) {
                Text(camera.modelEra)
                Text(camera.confidence.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CameraCandidate: Identifiable, Hashable {
    enum Confidence: String, Hashable {
        case primaryTarget = "Primary test target"
        case closestCandidate = "Closest candidate"
        case strongCandidate = "Strong candidate"
        case imageAppCandidate = "Image App candidate"
        case laterCandidate = "Later, unverified candidate"
    }

    let models: String
    let modelEra: String
    let confidence: Confidence

    var id: String { models }
}

struct CameraCandidateSection: Identifiable, Hashable {
    let title: String
    let detail: String
    let cameras: [CameraCandidate]

    var id: String { title }
}

enum CameraCompatibilityCatalog {
    static let sections: [CameraCandidateSection] = [
        CameraCandidateSection(
            title: "GM family · 2013–2014",
            detail: "The GM1, GM1S, and GM5 are the first hardware targets because they are the closest relatives.",
            cameras: [
                camera("Panasonic DMC-GM1", "Introduced c. 2013", .closestCandidate),
                camera("Panasonic DMC-GM1S", "Introduced c. 2014", .primaryTarget),
                camera("Panasonic DMC-GM5", "Introduced c. 2014", .closestCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Early system cameras · 2013–2015",
            detail: "These cameras belong to the early Wi-Fi/Image App generation and are strong protocol candidates.",
            cameras: [
                camera("Panasonic DMC-GF6", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-G6", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-GX7", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-GH4", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-GF7", "Introduced c. 2015", .strongCandidate),
                camera("Panasonic DMC-G7 / G70", "Introduced c. 2015", .strongCandidate),
                camera("Panasonic DMC-GX8", "Introduced c. 2015", .strongCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Mature system cameras · 2016–2019",
            detail: "Panasonic retained Image App for these models, but authorization and camera commands may differ.",
            cameras: [
                camera("Panasonic DMC-GF8", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-GX80 / GX85", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-G80 / G81 / G85", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DC-GF9 / GX800 / GX850", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-GH5", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-G9", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-GH5S", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-GF10", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-GX9", "Introduced c. 2018", .imageAppCandidate),
                camera("Panasonic DC-G90 / G91 / G95 / G95D", "Model era c. 2019+", .laterCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Early compact cameras · 2013–2015",
            detail: "These fixed-lens cameras used Panasonic Image App during the same broad protocol era.",
            cameras: [
                camera("Panasonic DMC-FT5 / TS5", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-TZ40 / TZ41 / TZ37 / ZS30 / ZS27", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-SZ9", "Introduced c. 2013", .imageAppCandidate),
                camera("Panasonic DMC-LF1", "Introduced c. 2013", .strongCandidate),
                camera("Panasonic DMC-TZ60 / TZ61 / ZS40 / SZ8", "Introduced c. 2014", .imageAppCandidate),
                camera("Panasonic DMC-TZ55 / TZ56 / ZS35", "Introduced c. 2014", .imageAppCandidate),
                camera("Panasonic DMC-FZ1000", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-LX100", "Introduced c. 2014", .strongCandidate),
                camera("Panasonic DMC-TZ70 / TZ71 / ZS50", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-TZ57 / TZ58 / ZS45", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-SZ10", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-FT6 / TS6", "Introduced c. 2015", .imageAppCandidate),
                camera("Panasonic DMC-FZ300 / FZ330", "Introduced c. 2015", .imageAppCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Later compact cameras · 2016–2019",
            detail: "Media browsing may be similar, but these cameras require real-device capability probes.",
            cameras: [
                camera("Panasonic DMC-TZ100 / TZ101 / TZ110 / ZS100 / ZS110", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-TZ80 / TZ81 / ZS60", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-FZ2000 / FZ2500", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DMC-LX9 / LX10 / LX15", "Introduced c. 2016", .imageAppCandidate),
                camera("Panasonic DC-FZ80 / FZ82", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-TZ90 / TZ91 / TZ92 / TZ93 / ZS70", "Introduced c. 2017", .imageAppCandidate),
                camera("Panasonic DC-TZ200 / TZ200D / TZ202 / TZ202D / TZ220 / TZ220D / ZS200 / ZS200D / ZS220 / ZS220D", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-FT7 / TS7", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-LX100M2", "Introduced c. 2018", .laterCandidate),
                camera("Panasonic DC-FZ1000M2 / FZ10002", "Introduced c. 2019", .laterCandidate),
                camera("Panasonic DC-TZ95 / TZ95D / TZ96 / TZ96D / TZ97 / ZS80 / ZS80D", "Model era c. 2019+", .laterCandidate)
            ]
        ),
        CameraCandidateSection(
            title: "Recent Image App compacts · 2025–2026",
            detail: "Panasonic still lists these with Image App, but GM1 Sync does not assume they share the legacy protocol.",
            cameras: [
                camera("Panasonic DC-TZ99 / ZS99", "Introduced c. 2025", .laterCandidate),
                camera("Panasonic DC-TZ300 / ZS300", "Introduced c. 2026", .laterCandidate)
            ]
        )
    ]

    static var allCameras: [CameraCandidate] {
        sections.flatMap(\.cameras)
    }

    private static func camera(
        _ models: String,
        _ modelEra: String,
        _ confidence: CameraCandidate.Confidence
    ) -> CameraCandidate {
        CameraCandidate(models: models, modelEra: modelEra, confidence: confidence)
    }
}
