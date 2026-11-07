import Foundation

/// A scripted camera for UI tests, previews, and App Store captures. It answers
/// the same `cam.cgi` commands as a GM-family camera and never touches a network.
actor DemoRemoteCamera: RemoteCameraControlling {
    nonisolated let host = "192.168.54.1"
    nonisolated var belongsToCurrentConnection: Bool { true }

    private var mode = "play"
    private var settings: [String: String] = [
        "iso": "auto", "whitebalance": "auto", "drivemode": "normal", "focusmode": "afs",
        "afmode": "1area", "exposure": "0", "focal": "1024/256", "shtrspeed": "1536/256"
    ]
    private var remainingPhotos = 512
    private var isRecording = false
    private var cardBusyUntil = Date.distantPast
    private var focusPosition = 500

    func perform(_ command: LumixCommand, timeoutInterval: TimeInterval?) async throws -> LumixCommandReply {
        try await Task.sleep(for: .milliseconds(15))
        return LumixCommandReply.parse(reply(to: command))
    }

    private func reply(to command: LumixCommand) -> String {
        switch (command.mode, command.type, command.value) {
        case ("getstate", _, _):
            return stateXML()
        case ("accctrl", "req_acc", _):
            return "ok,GM1S-DEMO01,remote,encrypted"
        case ("camcmd", _, "recmode"?):
            mode = "rec"
            return Self.ok
        case ("camcmd", _, "playmode"?):
            mode = "play"
            return Self.ok
        case ("camcmd", _, "capture"?):
            guard mode == "rec" else { return Self.error("err_reject") }
            remainingPhotos -= 1
            cardBusyUntil = Date().addingTimeInterval(0.6)
            return Self.ok
        case ("camcmd", _, "capture_cancel"?):
            return Self.ok
        case ("camcmd", _, "video_recstart"?):
            isRecording = true
            return Self.ok
        case ("camcmd", _, "video_recstop"?):
            isRecording = false
            cardBusyUntil = Date().addingTimeInterval(0.6)
            return Self.ok
        case ("camcmd", _, let value?) where value.hasPrefix("tele") || value.hasPrefix("wide") || value == "zoomstop":
            return Self.ok
        case ("startstream", _, _), ("stopstream", _, _):
            return Self.ok
        case ("getsetting", let type?, _):
            guard let value = settings[type] else { return Self.error("err_param") }
            return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><camrply><result>ok</result><settingvalue \(type)=\"\(value)\"></settingvalue></camrply>"
        case ("setsetting", let type?, let value?):
            settings[type] = value
            return Self.ok
        case ("getinfo", "capability"?, _):
            return Self.capabilityXML
        case ("getinfo", "allmenu"?, _):
            return Self.allMenuXML
        case ("getinfo", "curmenu"?, _):
            return curMenuXML()
        case ("getinfo", "lens"?, _):
            return "ok,2304/256,768/256,3584/256,-1536/256,0,on,32,12,on,128/1024,on"
        case ("camctrl", "touch"?, _):
            return Self.ok
        case ("camctrl", "focus"?, let value?):
            guard settings["focusmode"] == "mf" else { return Self.error("err_non_support") }
            let step = ["tele-normal": -4, "tele-fast": -40, "wide-normal": 4, "wide-fast": 40][value] ?? 0
            focusPosition = min(1000, max(0, focusPosition + step))
            return "ok,\(focusPosition),1000"
        default:
            return Self.error("err_param")
        }
    }

    private func stateXML() -> String {
        let busy = Date() < cardBusyUntil ? "on" : "off"
        return """
        <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result><state><batt>2/3</batt>\
        <cammode>\(mode)</cammode><remaincapacity>\(remainingPhotos)</remaincapacity>\
        <sdcardstatus>write_enable</sdcardstatus><sd_memory>set</sd_memory><video_remaincapacity>1800</video_remaincapacity>\
        <rec>\(isRecording ? "on" : "off")</rec><sd_access>\(busy)</sd_access><temperature>normal</temperature>\
        <lens>normal</lens><version>1.1</version></state></camrply>
        """
    }

    private func curMenuXML() -> String {
        let manual = settings["focusmode"] == "mf"
        return """
        <?xml version="1.0" encoding="utf-8"?><camrply><result>ok</result><menuinfo model="GM1S">
        <photosettings>
        <item id="menu_item_id_focusmode" enable="yes" value="\(settings["focusmode"] ?? "")" />
        <item id="menu_item_id_afmode" enable="\(manual ? "no" : "yes")" value="\(settings["afmode"] ?? "")" />
        </photosettings><qmenu2>
        <item id="menu_item_id_f_and_ss" enable="yes" />
        <item id="menu_item_id_sensitivity" enable="yes" value="\(settings["iso"] ?? "")" />
        <item id="menu_item_id_exposure3" enable="yes" value="\(settings["exposure"] ?? "")" />
        <item id="menu_item_id_whitebalance" enable="yes" value="\(settings["whitebalance"] ?? "")" />
        <item id="menu_item_id_drivemode" enable="yes" value="\(settings["drivemode"] ?? "")" />
        </qmenu2></menuinfo></camrply>
        """
    }

    private static let ok = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><camrply><result>ok</result></camrply>"

    private static func error(_ code: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><camrply><result>\(code)</result></camrply>"
    }

    private static let capabilityXML = """
    <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result><comm_proto_ver>1.3</comm_proto_ver>\
    <productinfo><modelname>GM1S-DEMO</modelname></productinfo><camcmdlist><camcmd>tele-normal</camcmd>\
    <camcmd>tele-fast</camcmd><camcmd>wide-normal</camcmd><camcmd>wide-fast</camcmd></camcmdlist>\
    <camspeclist><camspec>oneshot_af_enable</camspec></camspeclist></camrply>
    """

    private static let allMenuXML = """
    <?xml version="1.0" encoding="UTF-8"?><camrply><result>ok</result><menuset model="GM1S-DEMO" version="2.0">
    <photosettings><menu>
    <item id="menu_item_id_focusmode" title_id="t_focus" func_type="select"><group>
    <item id="menu_item_id_focusmode_afs" title_id="t_afs" cmd_mode="setsetting" cmd_type="focusmode" cmd_value="afs" />
    <item id="menu_item_id_focusmode_afc" title_id="t_afc" cmd_mode="setsetting" cmd_type="focusmode" cmd_value="afc" />
    <item id="menu_item_id_focusmode_mf" title_id="t_mf" cmd_mode="setsetting" cmd_type="focusmode" cmd_value="mf" />
    </group></item>
    <item id="menu_item_id_afmode" title_id="t_afmode" func_type="select"><group>
    <item id="menu_item_id_afmode_facedetection" title_id="t_face" cmd_mode="setsetting" cmd_type="afmode" cmd_value="facedetection" />
    <item id="menu_item_id_afmode_23area" title_id="t_23" cmd_mode="setsetting" cmd_type="afmode" cmd_value="23area" />
    <item id="menu_item_id_afmode_1area" title_id="t_1" cmd_mode="setsetting" cmd_type="afmode" cmd_value="1area" />
    </group></item>
    </menu></photosettings>
    <qmenu2><menu>
    <item id="menu_item_id_sensitivity" title_id="t_iso" func_type="sp_embeded_sensitivity"><group>
    <item id="menu_item_id_sensitivity_auto" title_id="t_iso_auto" cmd_mode="setsetting" cmd_type="iso" cmd_value="auto" />
    <item id="menu_item_id_sensitivity_200" title_id="t_200" cmd_mode="setsetting" cmd_type="iso" cmd_value="200" />
    <item id="menu_item_id_sensitivity_400" title_id="t_400" cmd_mode="setsetting" cmd_type="iso" cmd_value="400" />
    <item id="menu_item_id_sensitivity_800" title_id="t_800" cmd_mode="setsetting" cmd_type="iso" cmd_value="800" />
    <item id="menu_item_id_sensitivity_1600" title_id="t_1600" cmd_mode="setsetting" cmd_type="iso" cmd_value="1600" />
    </group></item>
    <item id="menu_item_id_exposure3" title_id="t_ev" func_type="sp_embeded_exposure3"><group>
    <item id="menu_item_id_exposure_m1" title_id="t_m1" cmd_mode="setsetting" cmd_type="exposure" cmd_value="-1" />
    <item id="menu_item_id_exposure_m1_3" title_id="t_m13" cmd_mode="setsetting" cmd_type="exposure" cmd_value="-1/3" />
    <item id="menu_item_id_exposure_0" title_id="t_0" cmd_mode="setsetting" cmd_type="exposure" cmd_value="0" />
    <item id="menu_item_id_exposure_p1_3" title_id="t_p13" cmd_mode="setsetting" cmd_type="exposure" cmd_value="1/3" />
    <item id="menu_item_id_exposure_p1" title_id="t_p1" cmd_mode="setsetting" cmd_type="exposure" cmd_value="1" />
    </group></item>
    <item id="menu_item_id_whitebalance" title_id="t_wb" func_type="sp_embeded_whitebalance"><group>
    <item id="menu_item_id_whitebalance_auto" title_id="t_awb" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="auto" />
    <item id="menu_item_id_whitebalance_daylight" title_id="t_day" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="daylight" />
    <item id="menu_item_id_whitebalance_cloudy" title_id="t_cloud" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="cloudy" />
    <item id="menu_item_id_whitebalance_color_temp" title_id="t_k" cmd_mode="setsetting" cmd_type="whitebalance" cmd_value="color_temp" cmd_value2="__value__" />
    </group></item>
    <item id="menu_item_id_drivemode" title_id="t_drive" func_type="sp_embeded_drivemode"><group>
    <item id="menu_item_id_1shoot" title_id="t_single" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="normal" />
    <item id="menu_item_id_burst" title_id="t_burst" func_type="select" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst"><group>
    <item id="menu_item_id_burst_h" title_id="t_h" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst" cmd_value2="h" />
    <item id="menu_item_id_burst_l" title_id="t_l" cmd_mode="setsetting" cmd_type="drivemode" cmd_value="burst" cmd_value2="l" />
    </group></item>
    </group></item>
    </menu></qmenu2>
    <titlelist><language code="en" default="yes">
    <title id="t_focus">Focus Mode</title><title id="t_afs">AFS</title><title id="t_afc">AFC</title><title id="t_mf">MF</title>
    <title id="t_afmode">AF Mode</title><title id="t_face">Face Detection</title><title id="t_23">23-Area</title><title id="t_1">1-Area</title>
    <title id="t_iso">Sensitivity</title><title id="t_iso_auto">Auto</title><title id="t_200">200</title><title id="t_400">400</title>
    <title id="t_800">800</title><title id="t_1600">1600</title><title id="t_ev">Exposure Comp.</title>
    <title id="t_m1">-1</title><title id="t_m13">-1/3</title><title id="t_0">0</title><title id="t_p13">+1/3</title><title id="t_p1">+1</title>
    <title id="t_wb">White Balance</title><title id="t_awb">Auto White Balance</title><title id="t_day">Daylight</title>
    <title id="t_cloud">Cloudy</title><title id="t_k">Color Temperature</title><title id="t_drive">Drive Mode</title>
    <title id="t_single">Single</title><title id="t_burst">Burst Shooting</title><title id="t_h">H</title><title id="t_l">L</title>
    </language></titlelist></menuset></camrply>
    """
}

/// Generates synthetic live-view datagrams and feeds them through the real packet
/// parser and JPEG decoder. The low frame rate keeps UI tests able to reach idle.
final class DemoLiveViewSource: LumixLiveViewSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.web3.gm1sync.demo-live-view")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var tick = 0

    func start(handler: @escaping @Sendable (LumixLiveViewEvent) -> Void) throws -> UInt16 {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick += 1
            let phase = 0.15 + 0.7 * (0.5 + 0.5 * sin(Double(self.tick) / 5))
            guard let jpeg = LumixLiveViewPacketBuilder.syntheticJPEG(phase: phase) else { return }
            let frame = LumixLiveViewFrameMetadata.AFFrame(
                x0: 400, y0: 380, x1: 600, y1: 620, red: 0, green: 220, blue: 0, kind: 1
            )
            let datagram = LumixLiveViewPacketBuilder.datagram(jpeg: jpeg, extensionType: 5, frames: [frame])
            handler(LumixLiveViewDecoder.decode(datagram))
        }
        lock.withLock { self.timer = timer }
        timer.resume()
        return 49199
    }

    func stop() {
        let timer: DispatchSourceTimer? = lock.withLock {
            let current = self.timer
            self.timer = nil
            return current
        }
        timer?.cancel()
    }
}
