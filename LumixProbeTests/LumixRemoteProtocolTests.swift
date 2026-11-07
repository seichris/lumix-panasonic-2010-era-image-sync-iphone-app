import Foundation
import XCTest
@testable import GM1Sync

final class LumixRemoteProtocolTests: XCTestCase {
    func testXMLRepliesExposeResultAndBody() {
        let ok = LumixCommandReply.parse("""
        \u{FEFF}  <?xml version="1.0" encoding="UTF-8"?>
        <camrply><result>ok</result><settingvalue iso="800"></settingvalue></camrply>
        """)
        XCTAssertTrue(ok.isOK)
        XCTAssertEqual(LumixSettingValue(reply: ok, type: "iso")?.value, "800")

        let busy = LumixCommandReply.parse("<?xml version=\"1.0\"?><camrply><result>err_busy</result></camrply>")
        XCTAssertTrue(busy.isBusy)
        XCTAssertFalse(busy.isOK)
        XCTAssertNil(LumixSettingValue(reply: busy, type: "iso"))
    }

    func testCSVRepliesKeepEveryField() {
        let reply = LumixCommandReply.parse("ok,GM1S-ABC123,remote,encrypted\r\n")
        XCTAssertTrue(reply.isOK)
        XCTAssertEqual(reply.fields, ["ok", "GM1S-ABC123", "remote", "encrypted"])
        XCTAssertTrue(LumixCommandReply.parse("ok_under_research").isAwaitingCameraApproval)
        XCTAssertEqual(LumixCommandReply.parse("err_param").result, "err_param")
    }

    func testMalformedAndEmptyRepliesNeverLookSuccessful() {
        let malformed = LumixCommandReply.parse("<camrply><result>ok</result><state><batt>1/3</state>")
        XCTAssertEqual(malformed.result, "ok", "The result code is recovered from malformed XML")
        XCTAssertNil(LumixCameraState(reply: malformed), "No state is invented from malformed XML")
        XCTAssertEqual(LumixCommandReply.parse("").result, LumixResultCode.noReply)
        XCTAssertEqual(LumixCommandReply.parse("<camrply><foo/></camrply>").result, "bad_xml")
    }

    func testCameraStateParsesTheKeepAliveSnapshot() throws {
        let reply = LumixCommandReply.parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <camrply><result>ok</result><state><batt>1/3</batt><cammode>rec</cammode><remaincapacity>675</remaincapacity>\
        <sdcardstatus>write_enable</sdcardstatus><sd_memory>set</sd_memory><video_remaincapacity>1012</video_remaincapacity>\
        <rec>off</rec><sd_access>on</sd_access><progress_time>12</progress_time><temperature>low</temperature>\
        <add_location_data>off</add_location_data><version>D2.91</version></state></camrply>
        """)
        let state = try XCTUnwrap(LumixCameraState(reply: reply))
        XCTAssertEqual(state.mode, .record)
        XCTAssertEqual(state.battery?.level, 1)
        XCTAssertEqual(state.battery?.maximum, 3)
        XCTAssertEqual(state.remainingPhotos, 675)
        XCTAssertEqual(state.remainingVideoSeconds, 1012)
        XCTAssertFalse(state.isRecordingVideo)
        XCTAssertTrue(state.isAccessingCard)
        XCTAssertEqual(state.isCardWritable, true)
        XCTAssertEqual(state.hasCard, true)
        XCTAssertEqual(state.videoProgressSeconds, 12)
        XCTAssertEqual(state.firmwareVersion, "D2.91")

        let noGrip = LumixCameraState(values: ["batt": "-1/0", "cammode": "play"])
        XCTAssertNil(noGrip.battery)
        XCTAssertEqual(noGrip.mode, .playback)
    }

    func testCommandQueryKeepsPanasonicParameterOrderAndRawSlashValues() throws {
        let command = LumixCommand.setSetting("exposure", value: "-1/3", value2: "x")
        XCTAssertEqual(command.queryItems.map(\.name), ["mode", "type", "value", "value2"])
        var components = URLComponents(string: "http://192.168.54.1/cam.cgi")!
        components.queryItems = LumixCommand.camctrl("touch", value: "250/750", value2: "on").queryItems
        XCTAssertEqual(components.url?.absoluteString,
                       "http://192.168.54.1/cam.cgi?mode=camctrl&type=touch&value=250/750&value2=on")
        XCTAssertEqual(LumixCommand.startStream(port: 49199).description, "mode=startstream&value=49199")
    }

    func testLensInfoAndAPEXLabels() throws {
        let lens = try XCTUnwrap(LumixLensInfo(reply: LumixCommandReply.parse("ok,2304/256,1094/256,3584/256,-1536/256,0,on,42,14,on,128/1024,on")))
        XCTAssertEqual(lens.apertureClosed, 9)
        XCTAssertEqual(try XCTUnwrap(lens.apertureOpen), 1094.0 / 256, accuracy: 0.0001)
        XCTAssertEqual(lens.shutterFastest, 14)
        XCTAssertEqual(lens.shutterSlowest, -6)
        XCTAssertEqual(lens.maximumFocalLength, 42)
        XCTAssertEqual(lens.minimumFocalLength, 14)
        XCTAssertTrue(lens.hasFocalLengthRange)
        XCTAssertNil(LumixLensInfo(reply: LumixCommandReply.parse("err_non_support")))

        XCTAssertEqual(LumixAPEX.apertureLabel(LumixAPEX.parse("768/256")), "f/2.8")
        XCTAssertEqual(LumixAPEX.apertureLabel(LumixAPEX.parse("1365/256")), "f/6.3")
        XCTAssertEqual(LumixAPEX.shutterLabel(LumixAPEX.parse("1451/256")), "1/50")
        XCTAssertEqual(LumixAPEX.shutterLabel(LumixAPEX.parse("1536/256")), "1/60")
        XCTAssertEqual(LumixAPEX.shutterLabel(LumixAPEX.parse("-256/256")), "2\"")
        XCTAssertEqual(LumixAPEX.compensationLabel("-4/3"), "−1⅓")
        XCTAssertEqual(LumixAPEX.compensationLabel("2/3"), "+⅔")
        XCTAssertEqual(LumixAPEX.compensationLabel("0"), "±0")
        XCTAssertNil(LumixAPEX.parse("1/0"))
    }

    func testExposureOptionsStayWithinTheLensRange() throws {
        let apertures = LumixAPEX.apertureOptions(open: 3, closed: 9)
        XCTAssertEqual(apertures.first?.label, "f/2.8")
        XCTAssertEqual(apertures.last?.label, "f/22")
        XCTAssertEqual(apertures.first?.value, "768/256")
        XCTAssertEqual(Set(apertures.map(\.value)).count, apertures.count)

        let shutters = LumixAPEX.shutterOptions(fastest: 14, slowest: -6)
        XCTAssertEqual(shutters.first?.label, "60\"")
        XCTAssertEqual(shutters.last?.label, "1/16000")
        XCTAssertTrue(shutters.contains { $0.label == "1/60" && $0.value == "1536/256" })
        XCTAssertTrue(LumixAPEX.shutterOptions(fastest: -6, slowest: 14).isEmpty)
    }

    func testMenuSchemaFlattensOptionsAndHonorsCurrentEnableFlags() throws {
        let schema = try XCTUnwrap(LumixMenuSchema.parse(Data(Self.allMenu.utf8)))
        XCTAssertEqual(schema.model, "GX80")
        let current = LumixCurrentMenu.parse(Self.curMenu)

        let controls = RemoteShootingControls.derive(
            schema: schema,
            currentMenu: current,
            values: [.iso: LumixSettingValue(type: "iso", value: "400"),
                     .driveMode: LumixSettingValue(type: "drivemode", value: "burst"),
                     .focusMode: LumixSettingValue(type: "focusmode", value: "mf")],
            aperture: LumixSettingValue(type: "focal", value: "1024/256"),
            shutter: LumixSettingValue(type: "shtrspeed", value: "1536/256"),
            lens: LumixLensInfo(reply: LumixCommandReply.parse("ok,2304/256,768/256,3584/256,-1536/256,0,on,14,14,on,128/1024,on")),
            capabilities: CameraCapabilities(model: nil, version: nil, date: nil, entries: [], commands: ["tele-normal"])
        )

        let iso = try XCTUnwrap(controls.settings.first { $0.kind == .iso })
        XCTAssertEqual(iso.options.map(\.label), ["i.Auto", "L.100", "200", "400"])
        XCTAssertEqual(iso.options.first { $0.value == "200" }?.isEnabled, false, "curmenu disables ISO 200")
        XCTAssertEqual(iso.currentLabel, "400")
        XCTAssertTrue(iso.canChange)

        let whiteBalance = try XCTUnwrap(controls.settings.first { $0.kind == .whiteBalance })
        XCTAssertEqual(whiteBalance.options.map(\.value), ["auto", "daylight"], "Placeholder colour-temperature values are skipped")
        XCTAssertFalse(whiteBalance.isEnabled, "curmenu disables white balance in this mode")

        let drive = try XCTUnwrap(controls.settings.first { $0.kind == .driveMode })
        XCTAssertEqual(drive.options.map(\.label), ["Single", "Burst Shooting · H", "Burst Shooting · L"])
        XCTAssertEqual(drive.options[1].command(for: .driveMode),
                       .setSetting("drivemode", value: "burst", value2: "h"))
        XCTAssertEqual(drive.currentLabel, "Burst Shooting")

        let exposure = try XCTUnwrap(controls.settings.first { $0.kind == .exposureCompensation })
        XCTAssertEqual(exposure.options.map(\.label), ["−⅓", "±0", "+⅓"])

        XCTAssertEqual(controls.exposureMode, .aperturePriority)
        XCTAssertEqual(controls.aperture?.isEnabled, true)
        XCTAssertEqual(controls.shutter?.isEnabled, false)
        XCTAssertEqual(controls.aperture?.currentLabel, "f/4.0")
        XCTAssertEqual(controls.shutter?.currentLabel, "1/60")
        XCTAssertTrue(controls.isManualFocus)
        XCTAssertFalse(controls.supportsPowerZoom, "A prime lens cannot zoom even when the camera lists zoom commands")
        XCTAssertTrue(controls.hasCameraMenus)
        XCTAssertNil(controls.settings.first { $0.kind == .peaking }, "Settings the camera does not list are not offered")
    }

    /// Trimmed from a GM1S (firmware 2.70) reply: menu set 2.0 names exposure
    /// compensation `exposure2`, and in P mode `getsetting` still reports the stored
    /// S/M shutter speed while the camera exposes at another one.
    func testGM1SMenuSetOffersExposureCompensationAndLeavesProgramValuesToTheCamera() throws {
        let schema = try XCTUnwrap(LumixMenuSchema.parse(Data("""
        <?xml version="1.0" encoding="utf-8"?><camrply><result>ok</result><menuset model="GM1S" version="2.0" date="20140825">\
        <photosettings><menu><item id="menu_item_id_aperture" title_id="title_aperture" func_type="sp_embeded_aperture" ></item>\
        <item id="menu_item_id_shutter_speed" title_id="title_shutter_speed" func_type="sp_embeded_shutter_speed" ></item>\
        <item id="menu_item_id_program_shift" title_id="title_program_shift" func_type="sp_embeded_program_shift" ></item>\
        <item id="menu_item_id_exposure2" title_id="title_exposure2" func_type="sp_embeded_exposure2" ><group>\
        <item id="menu_item_id_exposure_m14_3" title_id="title_exposure_m14_3" cmd_mode="setsetting" cmd_type="exposure" cmd_value="-14/3" ></item>\
        <item id="menu_item_id_exposure_m1_3" title_id="title_exposure_m1_3" cmd_mode="setsetting" cmd_type="exposure" cmd_value="-1/3" ></item>\
        <item id="menu_item_id_exposure_0" title_id="title_exposure_0" cmd_mode="setsetting" cmd_type="exposure" cmd_value="0" ></item>\
        <item id="menu_item_id_exposure_p1_3" title_id="title_exposure_p1_3" cmd_mode="setsetting" cmd_type="exposure" cmd_value="1/3" ></item>\
        <item id="menu_item_id_exposure_p5" title_id="title_exposure_p5" cmd_mode="setsetting" cmd_type="exposure" cmd_value="5" ></item>\
        </group></item></menu></photosettings></menuset></camrply>
        """.utf8)))
        let current = LumixCurrentMenu.parse("""
        <?xml version="1.0" encoding="utf-8"?>
        <camrply><result>ok</result><menuinfo model="GM1S" version="2.0" ><photosettings>
        <item id="menu_item_id_focusmode" enable="no" value="afs" />
        <item id="menu_item_id_shutter_speed" enable="no" />
        <item id="menu_item_id_aperture" enable="no" />
        <item id="menu_item_id_program_shift" enable="yes" />
        <item id="menu_item_id_exposure2" enable="yes" value="0" />
        <item id="menu_item_id_exposure_m14_3" enable="yes" />
        </photosettings></menuinfo></camrply>
        """)

        let controls = RemoteShootingControls.derive(
            schema: schema,
            currentMenu: current,
            values: [.exposureCompensation: LumixSettingValue(type: "exposure", value: "0"),
                     .focusMode: LumixSettingValue(type: "focusmode", value: "afs")],
            aperture: LumixSettingValue(type: "focal", value: "392/256"),
            shutter: LumixSettingValue(type: "shtrspeed", value: "2048/256"),
            lens: LumixLensInfo(reply: LumixCommandReply.parse("ok,2048/256,392/256,3584/256,-1536/256,0,off,15,15,on,128/1024,on")),
            capabilities: nil
        )

        let exposure = try XCTUnwrap(controls.settings.first { $0.kind == .exposureCompensation })
        XCTAssertTrue(exposure.canChange, "P mode allows exposure compensation")
        XCTAssertEqual(exposure.options.map(\.label), ["−4⅔", "−⅓", "±0", "+⅓", "+5"])
        XCTAssertEqual(exposure.currentLabel, "±0")
        XCTAssertEqual(exposure.options.last?.command(for: .exposureCompensation), .setSetting("exposure", value: "5"))
        XCTAssertEqual(RemoteShootingSetting.Kind.exposureCompensation.menuItemID(schema: schema, currentMenu: current),
                       "menu_item_id_exposure2")
        XCTAssertFalse(exposure.groupsCompensationOptions, "Five options fit one menu")
        let groups = exposure.compensationGroups
        XCTAssertEqual(groups.neutral.map(\.label), ["±0"])
        XCTAssertEqual(groups.brighter.map(\.label), ["+⅓", "+5"])
        XCTAssertEqual(groups.darker.map(\.label), ["−⅓", "−4⅔"], "Each side starts next to ±0")

        let focus = try XCTUnwrap(controls.settings.first { $0.kind == .focusMode })
        XCTAssertFalse(focus.canChange, "The GM1S remote menu does not offer focus modes")
        XCTAssertEqual(focus.currentLabel, "AFS")

        XCTAssertEqual(controls.exposureMode, .program)
        let shutter = try XCTUnwrap(controls.shutter)
        XCTAssertFalse(shutter.isEnabled)
        XCTAssertTrue(shutter.isChosenByCamera)
        XCTAssertEqual(shutter.fallbackLabel, "Auto", "The stored 1/250 is not the speed the camera uses in P")
        XCTAssertEqual(controls.aperture?.fallbackLabel, "Auto")

        let manual = RemoteShootingControls.derive(
            schema: schema,
            currentMenu: LumixCurrentMenu.parse("<menuinfo><item id=\"menu_item_id_f_and_ss\" enable=\"yes\" /></menuinfo>"),
            values: [:],
            aperture: LumixSettingValue(type: "focal", value: "392/256"),
            shutter: LumixSettingValue(type: "shtrspeed", value: "2048/256"),
            lens: LumixLensInfo(reply: LumixCommandReply.parse("ok,2048/256,392/256,3584/256,-1536/256,0,off,15,15,on,128/1024,on")),
            capabilities: nil
        )
        XCTAssertEqual(manual.shutter?.isChosenByCamera, false)
        XCTAssertEqual(manual.shutter?.fallbackLabel, "1/250")

        let unknownMode = RemoteShootingControls.derive(
            schema: nil, currentMenu: nil, values: [:], aperture: nil,
            shutter: LumixSettingValue(type: "shtrspeed", value: "2048/256"),
            lens: LumixLensInfo(reply: LumixCommandReply.parse("ok,2048/256,392/256,3584/256,-1536/256,0,off,15,15,on,128/1024,on")),
            capabilities: nil
        )
        XCTAssertEqual(unknownMode.shutter?.fallbackLabel, "1/250", "Without curmenu the mode is unknown, so the stored value stays")
    }

    func testTheFullGM1SExposureRangeIsSplitAroundZero() {
        let values = (-15...15).map { thirds in thirds % 3 == 0 ? "\(thirds / 3)" : "\(thirds)/3" }
        let setting = RemoteShootingSetting(
            kind: .exposureCompensation, title: "Exposure", isEnabled: true, currentValue: "1", currentLabel: "+1",
            options: values.map { .init(id: "ev\($0)", label: LumixAPEX.compensationLabel($0), value: $0, value2: nil, isEnabled: true) }
        )
        XCTAssertTrue(setting.groupsCompensationOptions)
        let groups = setting.compensationGroups
        XCTAssertEqual(groups.neutral.map(\.value), ["0"])
        XCTAssertEqual(groups.brighter.count, 15)
        XCTAssertEqual(groups.brighter.prefix(4).map(\.label), ["+⅓", "+⅔", "+1", "+1⅓"])
        XCTAssertEqual(groups.darker.prefix(2).map(\.label), ["−⅓", "−⅔"])
        XCTAssertEqual(groups.darker.last?.label, "−5")
    }

    func testCameraErrorPagesAreShownAsText() {
        let overloaded = """
        <HTML><HEAD><TITLE>503 Service Temporarily Overloaded</TITLE></HEAD>
        <BODY BGCOLOR="#cc9999"><H2>503 Service Temporarily Overloaded</H2>
        <HR>The requested URL is temporarily overloaded. Please try again later.</BODY></HTML>
        """
        let busy = LumixError.http(503, overloaded).localizedDescription
        XCTAssertFalse(busy.contains("<"))
        XCTAssertTrue(busy.contains("busy"))
        XCTAssertEqual(
            LumixError.http(500, "<HTML><HEAD><TITLE>500</TITLE></HEAD><BODY><H2>Internal  Error</H2>\n</BODY></HTML>").localizedDescription,
            "HTTP 500: Internal Error"
        )
        XCTAssertEqual(LumixError.http(404, "Not Found").localizedDescription, "HTTP 404: Not Found")
    }

    func testWithoutAMenuSchemaSettingsAreReadOnly() {
        let controls = RemoteShootingControls.derive(
            schema: nil, currentMenu: nil,
            values: [.iso: LumixSettingValue(type: "iso", value: "auto")],
            aperture: nil, shutter: nil, lens: nil, capabilities: nil
        )
        XCTAssertEqual(controls.settings.map(\.kind), [.iso])
        XCTAssertFalse(controls.settings[0].canChange)
        XCTAssertEqual(controls.settings[0].currentLabel, "Auto")
        XCTAssertFalse(controls.hasCameraMenus)
        XCTAssertNil(controls.aperture)
        XCTAssertEqual(controls.exposureMode, .unknown)
    }

    func testCurrentMenuToleratesMalformedAttributesAndInfersTheModeDial() {
        let menu = LumixCurrentMenu.parse("""
        <menuinfo><item id="menu_item_id_f_and_ss" enable="yes" /><item id="menu_item_id_broken" enable="no" /0>
        <item id="menu_item_id_sensitivity" enable="yes" value="auto" /></menuinfo>
        """)
        XCTAssertEqual(menu.exposureMode, .manual)
        XCTAssertEqual(menu.value("menu_item_id_sensitivity"), "auto")
        XCTAssertFalse(menu.isEnabled("menu_item_id_broken"))
        XCTAssertTrue(menu.isEnabled("menu_item_id_missing"))
        XCTAssertEqual(LumixCurrentMenu.parse("<menuinfo><item id=\"menu_item_id_program_shift\" enable=\"yes\"/></menuinfo>").exposureMode, .program)
        XCTAssertEqual(LumixCurrentMenu.parse("<menuinfo><item id=\"menu_item_id_quality\"/></menuinfo>").exposureMode, .automatic)
        XCTAssertEqual(LumixCurrentMenu.parse("").exposureMode, .unknown)
    }

    func testCapabilityParserReadsProtocolModelCommandsAndSpecs() {
        let capabilities = CameraCapabilityParser.parse(Data("""
        <?xml version="1.0" encoding ="UTF-8"?><camrply><result>ok</result><comm_proto_ver>1.6</comm_proto_ver>\
        <productinfo><modelname>GX80</modelname></productinfo><camcmdlist><camcmd>tele-normal</camcmd>\
        <camcmd>wide-fast</camcmd></camcmdlist><camspeclist><camspec>oneshot_af_enable</camspec>\
        <camspec>geotag_add_enable</camspec></camspeclist><contents_action_info model="GX80" version="1.0">\
        <item><content mime_type="image/jpeg" panasonic_com_pn="CAM_ORG"><action type="copy_to_sp" enable="yes" /></content>\
        </item></contents_action_info></camrply>
        """.utf8))
        XCTAssertEqual(capabilities.protocolVersion, "1.6")
        XCTAssertEqual(capabilities.productModelName, "GX80")
        XCTAssertEqual(capabilities.commands, ["tele-normal", "wide-fast"])
        XCTAssertEqual(capabilities.specs, ["oneshot_af_enable", "geotag_add_enable"])
        XCTAssertTrue(capabilities.supportsPowerZoom)
        XCTAssertEqual(capabilities.model, "GX80")
        XCTAssertEqual(capabilities.entries.count, 1)
        XCTAssertFalse(CameraCapabilities(model: nil, version: nil, date: nil, entries: []).supportsPowerZoom)
    }

    func testFocusFeedbackParsesPositionAndRejectsErrors() {
        XCTAssertEqual(LumixFocusPosition(reply: LumixCommandReply.parse("ok,499,1024"))?.position, 499)
        XCTAssertEqual(try XCTUnwrap(LumixFocusPosition(reply: LumixCommandReply.parse("ok,512,1024"))?.fraction), 0.5, accuracy: 0.001)
        XCTAssertNil(LumixFocusPosition(reply: LumixCommandReply.parse("<camrply><result>err_non_support</result></camrply>")))
        XCTAssertNil(LumixFocusPosition(reply: LumixCommandReply.parse("ok,abc,1024")))
    }

    static let allMenu = """
    <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result><menuset model="GX80" version="2.0">
    <photosettings><menu>
    <item id="menu_item_id_focusmode" title_id="t_fm" func_type="select"><group>
    <item id="menu_item_id_focusmode_afs" title_id="t_afs" cmd_mode="setsetting" cmd_type="focusmode" cmd_value="afs" />
    <item id="menu_item_id_focusmode_mf" title_id="t_mf" cmd_mode="setsetting" cmd_type="focusmode" cmd_value="mf" />
    </group></item>
    </menu></photosettings>
    <qmenu2><menu>
    <item id="menu_item_id_sensitivity" title_id="t_iso" func_type="sp_embeded_sensitivity"><group>
    <item id="menu_item_id_sensitivity_auto" title_id="t_iso_a" cmd_mode="setsetting" cmd_type="iso" cmd_value="auto" />
    <item id="menu_item_id_sensitivity_100" title_id="t_iso_100" cmd_mode="setsetting" cmd_type="iso" cmd_value="100" />
    <item id="menu_item_id_sensitivity_200" title_id="t_iso_200" cmd_mode="setsetting" cmd_type="iso" cmd_value="200" />
    <item id="menu_item_id_sensitivity_400" title_id="t_iso_400" cmd_mode="setsetting" cmd_type="iso" cmd_value="400" />
    </group></item>
    <item id="menu_item_id_exposure3" title_id="t_ev" func_type="sp_embeded_exposure3"><group>
    <item id="menu_item_id_exposure_m1_3" title_id="t_m" cmd_mode="setsetting" cmd_type="exposure" cmd_value="-1/3" />
    <item id="menu_item_id_exposure_0" title_id="t_z" cmd_mode="setsetting" cmd_type="exposure" cmd_value="0" />
    <item id="menu_item_id_exposure_p1_3" title_id="t_p" cmd_mode="setsetting" cmd_type="exposure" cmd_value="1/3" />
    </group></item>
    <item id="menu_item_id_whitebalance" title_id="t_wb" func_type="sp_embeded_whitebalance"><group>
    <item id="menu_item_id_whitebalance_auto" title_id="t_awb" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="auto" />
    <item id="menu_item_id_whitebalance_daylight" title_id="t_day" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="daylight" />
    <item id="menu_item_id_whitebalance_color_temp" title_id="t_k" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="color_temp" cmd_value2="__value__" />
    </group></item>
    <item id="menu_item_id_drivemode" title_id="t_drive" func_type="sp_embeded_drivemode"><group>
    <item id="menu_item_id_1shoot" title_id="t_single" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="normal" />
    <item id="menu_item_id_burst" title_id="t_burst" func_type="select" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst"><group>
    <item id="menu_item_id_burst_h" title_id="t_h" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst" cmd_value2="h" />
    <item id="menu_item_id_burst_l" title_id="t_l" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst" cmd_value2="l" />
    </group></item>
    <item id="menu_item_id_drvmod_off" title_id="t_off" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="normal" />
    </group></item>
    </menu></qmenu2>
    <titlelist><language code="ja"><title id="t_iso">感度</title></language><language code="en" default="yes">
    <title id="t_fm">Focus Mode</title><title id="t_afs">AFS</title><title id="t_mf">MF</title>
    <title id="t_iso">Sensitivity</title><title id="t_iso_a">i.Auto</title><title id="t_iso_100">L.100</title>
    <title id="t_iso_200">200</title><title id="t_iso_400">400</title><title id="t_ev">Exposure Comp.</title>
    <title id="t_wb">White Balance</title><title id="t_awb">AWB</title><title id="t_day">Daylight</title><title id="t_k">K</title>
    <title id="t_drive">Drive Mode</title><title id="t_single">Single</title><title id="t_burst">Burst Shooting</title>
    <title id="t_h">H</title><title id="t_l">L</title><title id="t_off">Off</title>
    </language></titlelist></menuset></camrply>
    """

    static let curMenu = """
    <?xml version="1.0" encoding="utf-8"?><camrply><result>ok</result><menuinfo model="GX7MK2" version="2.0">
    <qmenu2>
    <item id="menu_item_id_aperture" enable="yes" />
    <item id="menu_item_id_shutter_speed" enable="no" />
    <item id="menu_item_id_f_and_ss" enable="no" />
    <item id="menu_item_id_sensitivity" enable="yes" value="400" />
    <item id="menu_item_id_sensitivity_200" enable="no" />
    <item id="menu_item_id_whitebalance" enable="no" value="auto" />
    <item id="menu_item_id_drivemode" enable="yes" value="burst" />
    </qmenu2></menuinfo></camrply>
    """
}
