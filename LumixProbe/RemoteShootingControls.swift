import Foundation

/// A camera setting the remote shooting screen can show and, when the camera
/// advertises its options, change.
struct RemoteShootingSetting: Equatable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case iso
        case exposureCompensation
        case whiteBalance
        case driveMode
        case focusMode
        case afMode
        case peaking

        var id: String { rawValue }

        /// The `allmenu` entries that may list this setting's options, in order of
        /// preference. Menu sets name some entries differently: the GM1S (menu set 2.0)
        /// lists exposure compensation as `exposure2`.
        var menuItemIDs: [String] {
            switch self {
            case .iso: ["menu_item_id_sensitivity"]
            case .exposureCompensation: ["menu_item_id_exposure3", "menu_item_id_exposure2"]
            case .whiteBalance: ["menu_item_id_whitebalance"]
            case .driveMode: ["menu_item_id_drivemode"]
            case .focusMode: ["menu_item_id_focusmode"]
            case .afMode: ["menu_item_id_afmode"]
            case .peaking: ["menu_item_id_peaking"]
            }
        }

        /// The entry this camera uses: the first one its menu schema lists, else the
        /// first one its current menu reports.
        func menuItemID(schema: LumixMenuSchema?, currentMenu: LumixCurrentMenu?) -> String {
            menuItemIDs.first { schema?.item($0) != nil }
                ?? menuItemIDs.first { currentMenu?.entries[$0] != nil }
                ?? menuItemIDs[0]
        }

        /// The `getsetting`/`setsetting` type.
        var settingType: String {
            switch self {
            case .iso: "iso"
            case .exposureCompensation: "exposure"
            case .whiteBalance: "whitebalance"
            case .driveMode: "drivemode"
            case .focusMode: "focusmode"
            case .afMode: "afmode"
            case .peaking: "peaking"
            }
        }

        var title: String {
            switch self {
            case .iso: "ISO"
            case .exposureCompensation: "Exposure"
            case .whiteBalance: "White balance"
            case .driveMode: "Drive"
            case .focusMode: "Focus"
            case .afMode: "AF area"
            case .peaking: "Peaking"
            }
        }
    }

    struct Option: Hashable, Identifiable, Sendable {
        let id: String
        let label: String
        let value: String
        let value2: String?
        let isEnabled: Bool

        func command(for kind: Kind) -> LumixCommand {
            .setSetting(kind.settingType, value: value, value2: value2)
        }
    }

    let kind: Kind
    let title: String
    let isEnabled: Bool
    let currentValue: String?
    let currentLabel: String
    let options: [Option]

    var id: String { kind.rawValue }
    var canChange: Bool { isEnabled && options.contains(where: \.isEnabled) }

    func isCurrent(_ option: Option) -> Bool {
        guard let currentValue else { return false }
        return option.value == currentValue
    }
}

extension RemoteShootingSetting {
    /// Exposure compensation split around ±0, each side ordered outward from ±0, so a
    /// long range (the GM1S offers −5…+5 in thirds) opens at the values used most.
    struct CompensationGroups: Equatable, Sendable {
        var neutral: [Option] = []
        var brighter: [Option] = []
        var darker: [Option] = []
    }

    /// True when the options are too many for one menu that opens at its first entry.
    var groupsCompensationOptions: Bool { kind == .exposureCompensation && options.count > 9 }

    var compensationGroups: CompensationGroups {
        var groups = CompensationGroups()
        var values: [String: Double] = [:]
        for option in options {
            guard let value = LumixAPEX.parse(option.value), abs(value) > 0.01 else {
                groups.neutral.append(option)
                continue
            }
            values[option.id] = value
            if value > 0 { groups.brighter.append(option) } else { groups.darker.append(option) }
        }
        groups.brighter.sort { values[$0.id, default: 0] < values[$1.id, default: 0] }
        groups.darker.sort { values[$0.id, default: 0] > values[$1.id, default: 0] }
        return groups
    }
}

/// Aperture or shutter speed, available in the A/S/M positions of the mode dial.
struct RemoteExposureControl: Equatable, Sendable {
    let title: String
    let settingType: String
    let options: [LumixExposureOption]
    let current: Double?
    let currentLabel: String
    let isEnabled: Bool
    /// The camera picks this value itself in the current mode (P, or the other
    /// control in A/S). `getsetting` then reports the stored A/S/M value, not the
    /// one in use, so it must not be shown as current.
    var isChosenByCamera = false

    /// What to show when live view carries no exposure readout.
    var fallbackLabel: String { isChosenByCamera ? "Auto" : currentLabel }

    func isCurrent(_ option: LumixExposureOption) -> Bool {
        guard let current else { return false }
        return abs(option.apex - current) < 0.04
    }
}

/// Everything the remote shooting screen may offer, derived from what the
/// connected camera reports: its menu schema (`allmenu`), the enable flags for
/// the current shooting mode (`curmenu`), current values (`getsetting`), the
/// lens range (`getinfo&type=lens`), and capability flags.
struct RemoteShootingControls: Equatable, Sendable {
    var settings: [RemoteShootingSetting] = []
    var exposureMode: LumixExposureMode = .unknown
    var aperture: RemoteExposureControl?
    var shutter: RemoteExposureControl?
    var supportsPowerZoom = false
    var isManualFocus = false
    /// False when the camera did not provide `allmenu`; settings are then read-only.
    var hasCameraMenus = false

    static func derive(
        schema: LumixMenuSchema?,
        currentMenu: LumixCurrentMenu?,
        values: [RemoteShootingSetting.Kind: LumixSettingValue],
        aperture apertureValue: LumixSettingValue?,
        shutter shutterValue: LumixSettingValue?,
        lens: LumixLensInfo?,
        capabilities: CameraCapabilities?
    ) -> RemoteShootingControls {
        var controls = RemoteShootingControls()
        controls.hasCameraMenus = schema != nil
        controls.exposureMode = currentMenu?.exposureMode ?? .unknown

        for kind in RemoteShootingSetting.Kind.allCases {
            let menuItemID = kind.menuItemID(schema: schema, currentMenu: currentMenu)
            let current = values[kind]?.value ?? currentMenu?.value(menuItemID)
            let menuItem = schema?.item(menuItemID)
            let options = menuItem.map { flattenedOptions(of: $0, kind: kind, currentMenu: currentMenu) } ?? []
            guard menuItem != nil || current != nil else { continue }
            let isEnabled = menuItem != nil && (currentMenu?.isEnabled(menuItemID, default: !options.isEmpty) ?? true)
            controls.settings.append(
                RemoteShootingSetting(
                    kind: kind,
                    title: kind.title,
                    isEnabled: isEnabled,
                    currentValue: current,
                    currentLabel: label(for: current, kind: kind, options: options),
                    options: options
                )
            )
        }

        controls.isManualFocus = values[.focusMode]?.value.lowercased() == "mf"

        if let lens, let open = lens.apertureOpen, let closed = lens.apertureClosed {
            let current = LumixAPEX.parse(apertureValue?.value)
            controls.aperture = RemoteExposureControl(
                title: "Aperture",
                settingType: "focal",
                options: LumixAPEX.apertureOptions(open: open, closed: closed),
                current: current,
                currentLabel: LumixAPEX.apertureLabel(current),
                isEnabled: controls.exposureMode.allowsApertureChange,
                isChosenByCamera: controls.exposureMode != .unknown && !controls.exposureMode.allowsApertureChange
            )
        }
        if let lens, let fastest = lens.shutterFastest, let slowest = lens.shutterSlowest {
            let current = LumixAPEX.parse(shutterValue?.value)
            controls.shutter = RemoteExposureControl(
                title: "Shutter",
                settingType: "shtrspeed",
                options: LumixAPEX.shutterOptions(fastest: fastest, slowest: slowest),
                current: current,
                currentLabel: LumixAPEX.shutterLabel(current),
                isEnabled: controls.exposureMode.allowsShutterChange,
                isChosenByCamera: controls.exposureMode != .unknown && !controls.exposureMode.allowsShutterChange
            )
        }

        // Power zoom needs both a camera that lists the zoom commands and a lens that reports a range.
        controls.supportsPowerZoom = (capabilities?.supportsPowerZoom ?? false) && (lens?.hasFocalLengthRange ?? true)
        return controls
    }

    /// Flattens a select menu into settable options. Nested selections such as
    /// burst speeds become individual options; placeholder values are skipped.
    static func flattenedOptions(
        of item: LumixMenuItem,
        kind: RemoteShootingSetting.Kind,
        currentMenu: LumixCurrentMenu?,
        groupTitle: String? = nil
    ) -> [RemoteShootingSetting.Option] {
        var options: [RemoteShootingSetting.Option] = []
        var seenCommands = Set<String>()
        for child in item.children {
            let nested = child.children.filter { !$0.requiresAdditionalValue && $0.commandValue != nil }
            if !nested.isEmpty {
                for option in flattenedOptions(of: child, kind: kind, currentMenu: currentMenu, groupTitle: child.title) {
                    if seenCommands.insert(option.value + "|" + (option.value2 ?? "")).inserted { options.append(option) }
                }
                continue
            }
            guard !child.requiresAdditionalValue,
                  child.commandMode == "setsetting",
                  child.commandType?.caseInsensitiveCompare(kind.settingType) == .orderedSame,
                  let value = child.commandValue?.nonEmptyValue else { continue }
            let value2 = child.commandValue2?.nonEmptyValue
            guard seenCommands.insert(value + "|" + (value2 ?? "")).inserted else { continue }
            let title = child.title.nonEmptyValue ?? value
            let label: String
            if kind == .exposureCompensation {
                label = LumixAPEX.compensationLabel(value)
            } else if let groupTitle {
                label = "\(groupTitle) · \(title)"
            } else {
                label = title
            }
            options.append(
                RemoteShootingSetting.Option(
                    id: child.id,
                    label: label,
                    value: value,
                    value2: value2,
                    isEnabled: currentMenu?.isEnabled(child.id) ?? true
                )
            )
        }
        return options
    }

    private static func label(
        for value: String?,
        kind: RemoteShootingSetting.Kind,
        options: [RemoteShootingSetting.Option]
    ) -> String {
        guard let value else { return "–" }
        if kind == .exposureCompensation { return LumixAPEX.compensationLabel(value) }
        if let option = options.first(where: { $0.value == value }) {
            // Prefer the group's own title for nested options ("Burst Shooting" rather than one speed).
            return option.label.components(separatedBy: " · ").first ?? option.label
        }
        switch kind {
        case .iso: return value.lowercased() == "auto" ? "Auto" : value
        case .focusMode: return value.uppercased()
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
