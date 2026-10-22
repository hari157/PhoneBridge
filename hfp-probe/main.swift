// HFPProbe: Phase 1 test for IOBluetoothHandsFreeDevice.
// The Mac acts as the HFP Hands-Free unit. The paired phone is the Audio Gateway.
// Every event goes to the window and to ~/Library/Logs/HFPProbe/probe.log.
// Commands can also come from ~/Library/Logs/HFPProbe/cmd.txt (one per line).

import AppKit
import CoreAudio
import IOBluetooth

let logDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/HFPProbe")
let logURL = logDir.appendingPathComponent("probe.log")
let cmdURL = logDir.appendingPathComponent("cmd.txt")

// MARK: - Core Audio device listing

func audioDevices() -> [String] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { id in
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name)
        let n = name?.takeRetainedValue() as String? ?? "?"
        return "\(n) [in:\(channels(id, kAudioObjectPropertyScopeInput)) out:\(channels(id, kAudioObjectPropertyScopeOutput)) rate:\(sampleRate(id))]"
    }
}

func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func sampleRate(_ id: AudioObjectID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
    return Int(rate)
}

// MARK: - Channel remap (OnePlus 7T advertises HFP AG on channel 1 but listens on channel 3)

var rfcommRemapFrom: BluetoothRFCOMMChannelID = 0
var rfcommRemapTo: BluetoothRFCOMMChannelID = 0
var remapLog: ((String) -> Void)?

extension IOBluetoothDevice {
    @objc dynamic func probe_openRFCOMMChannelAsync(_ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!,
                                                    withChannelID id: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        var target = id
        if rfcommRemapTo != 0 && id == rfcommRemapFrom { target = rfcommRemapTo; remapLog?("remap async RFCOMM \(id) -> \(target)") }
        return probe_openRFCOMMChannelAsync(channel, withChannelID: target, delegate: delegate)
    }
    @objc dynamic func probe_openRFCOMMChannelSync(_ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!,
                                                   withChannelID id: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        var target = id
        if rfcommRemapTo != 0 && id == rfcommRemapFrom { target = rfcommRemapTo; remapLog?("remap sync RFCOMM \(id) -> \(target)") }
        return probe_openRFCOMMChannelSync(channel, withChannelID: target, delegate: delegate)
    }
}

extension IOBluetoothSDPServiceRecord {
    @objc dynamic func probe_getRFCOMMChannelID(_ p: UnsafeMutablePointer<BluetoothRFCOMMChannelID>!) -> IOReturn {
        let r = probe_getRFCOMMChannelID(p)
        if rfcommRemapTo != 0, r == kIOReturnSuccess, p.pointee == rfcommRemapFrom {
            p.pointee = rfcommRemapTo; remapLog?("remap SDP channel \(rfcommRemapFrom) -> \(rfcommRemapTo)")
        }
        return r
    }
}

func installRemapSwizzles() {
    func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        if let m1 = class_getInstanceMethod(cls, a), let m2 = class_getInstanceMethod(cls, b) { method_exchangeImplementations(m1, m2) }
    }
    swap(IOBluetoothDevice.self, #selector(IOBluetoothDevice.openRFCOMMChannelAsync(_:withChannelID:delegate:)),
         #selector(IOBluetoothDevice.probe_openRFCOMMChannelAsync(_:withChannelID:delegate:)))
    swap(IOBluetoothDevice.self, #selector(IOBluetoothDevice.openRFCOMMChannelSync(_:withChannelID:delegate:)),
         #selector(IOBluetoothDevice.probe_openRFCOMMChannelSync(_:withChannelID:delegate:)))
    swap(IOBluetoothSDPServiceRecord.self, #selector(IOBluetoothSDPServiceRecord.getRFCOMMChannelID(_:)),
         #selector(IOBluetoothSDPServiceRecord.probe_getRFCOMMChannelID(_:)))
}

// MARK: - Probe

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let logView = NSTextView()
    let devicePopup = NSPopUpButton()
    let numberField = NSTextField()
    var hf: IOBluetoothHandsFreeDevice?
    var paired: [IOBluetoothDevice] = []
    var lastAudio: [String] = []
    var cmdTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? "".write(to: cmdURL, atomically: true, encoding: .utf8)
        installRemapSwizzles()
        remapLog = { [weak self] in self?.log($0) }
        buildWindow()
        log("HFPProbe started. macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("Bluetooth power: \(IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON ? "on" : "off or unknown")")
        refreshDevices()
        lastAudio = audioDevices()
        log("Audio devices at start:\n  " + lastAudio.joined(separator: "\n  "))
        watchAudioDevices()
        publishHF()
        cmdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollCommands() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    // MARK: UI

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "HFP Probe"
        window.center()

        numberField.placeholderString = "Phone number"
        let rows: [[NSView]] = [
            [devicePopup, button("Refresh", #selector(refreshDevices)), button("Connect", #selector(connectSelected)), button("Disconnect", #selector(disconnect))],
            [numberField, button("Dial", #selector(dialField)), button("Answer", #selector(answer)), button("End / Reject", #selector(endCall))],
            [button("Audio to Mac", #selector(audioToMac)), button("Audio to Phone", #selector(audioToPhone)), button("Call list", #selector(callList)), button("Audio devices", #selector(listAudio)), button("Status", #selector(status))],
        ]
        let stack = NSStackView(views: rows.map { NSStackView(views: $0) })
        stack.orientation = .vertical
        stack.alignment = .leading

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        logView.autoresizingMask = [.width]

        let root = NSStackView(views: [stack, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),
            numberField.widthAnchor.constraint(equalToConstant: 180),
            devicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        DispatchQueue.main.async {
            self.logView.textStorage?.append(NSAttributedString(string: line, attributes: [.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]))
            self.logView.scrollToEndOfDocument(nil)
        }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Actions

    @objc func refreshDevices() {
        paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devicePopup.removeAllItems()
        for d in paired {
            let ag = d.handsFreeAudioGatewayServiceRecord() != nil
            devicePopup.addItem(withTitle: "\(d.name ?? "?") \(d.addressString ?? "") \(ag ? "[HFP AG]" : "")")
        }
        log("Paired devices: " + paired.map { "\($0.name ?? "?") (\($0.addressString ?? "")) AG=\($0.handsFreeAudioGatewayServiceRecord() != nil) connected=\($0.isConnected())" }.joined(separator: ", "))
        if let i = paired.firstIndex(where: { $0.handsFreeAudioGatewayServiceRecord() != nil }) {
            devicePopup.selectItem(at: i)
        }
    }

    func selectDevice(address: String?) -> IOBluetoothDevice? {
        if let a = address { return IOBluetoothDevice(addressString: a) }
        let i = devicePopup.indexOfSelectedItem
        return i >= 0 && i < paired.count ? paired[i] : nil
    }

    @objc func connectSelected() { connect(address: nil) }

    func connect(address: String?) {
        guard let dev = selectDevice(address: address) else { log("No device selected"); return }
        log("Connecting HFP to \(dev.name ?? "?") \(dev.addressString ?? "")")
        if let rec = dev.handsFreeAudioGatewayServiceRecord() {
            log("Phone AG SDP record found. AG features: 0x\(String(rec.handsFreeSupportedFeatures(), radix: 16))")
        } else {
            log("No HFP Audio Gateway SDP record in cache. Connect may still try a fresh SDP query.")
        }
        hf?.disconnect()
        guard let h = IOBluetoothHandsFreeDevice(device: dev, delegate: self) else { log("init returned nil"); return }
        hf = h
        log("Local HF supportedFeatures: 0x\(String(h.supportedFeatures, radix: 16))")
        h.connect()
    }

    @objc func disconnect() { hf?.disconnect(); log("disconnect() sent") }

    @objc func dialField() { dial(numberField.stringValue) }

    func dial(_ n: String) {
        let num = n.trimmingCharacters(in: .whitespaces)
        guard !num.isEmpty else { log("Enter a number first"); return }
        guard let h = hf else { log("Not connected"); return }
        log("dialNumber(\(num))"); h.dialNumber(num)
    }

    @objc func answer() { guard let h = hf else { log("Not connected"); return }; log("acceptCall()"); h.acceptCall() }
    @objc func endCall() { guard let h = hf else { log("Not connected"); return }; log("endCall()"); h.endCall() }
    @objc func audioToMac() { guard let h = hf else { log("Not connected"); return }; log("transferAudioToComputer()"); h.transferAudioToComputer() }
    @objc func audioToPhone() { guard let h = hf else { log("Not connected"); return }; log("transferAudioToPhone()"); h.transferAudioToPhone() }
    @objc func callList() { guard let h = hf else { log("Not connected"); return }; log("currentCallList() (AT+CLCC)"); h.currentCallList() }
    @objc func listAudio() { log("Audio devices:\n  " + audioDevices().joined(separator: "\n  ")) }

    @objc func status() {
        guard let h = hf else { log("Status: no HF object"); return }
        var s = "Status: connected=\(h.isConnected) sco=\(h.isSCOConnected())"
        s += " phoneFeatures=0x\(String(h.deviceSupportedFeatures, radix: 16))"
        s += " holdModes=0x\(String(h.deviceCallHoldModes, radix: 16))"
        for ind in ["service", "call", "callsetup", "callheld", "signal", "roam", "battchg"] {
            s += " \(ind)=\(h.indicator(ind))"
        }
        log(s)
    }

    // MARK: Command file (lets the terminal drive the same actions)

    func pollCommands() {
        guard let text = try? String(contentsOf: cmdURL, encoding: .utf8), !text.isEmpty else { return }
        try? "".write(to: cmdURL, atomically: true, encoding: .utf8)
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : nil
            log("cmd: \(raw)")
            switch parts.first ?? "" {
            case "devices": refreshDevices()
            case "connect": connect(address: arg)
            case "disconnect": disconnect()
            case "dial": dial(arg ?? "")
            case "answer": answer()
            case "end": endCall()
            case "audio-mac": audioToMac()
            case "audio-phone": audioToPhone()
            case "clcc": callList()
            case "audio": listAudio()
            case "status": status()
            case "at": if let a = arg { log("sendATCommand(\(a))"); hf?.send(atCommand: a) }
            case "sdp": listServices(address: arg)
            case "sdpquery":
                if let dev = selectDevice(address: arg) {
                    let r = dev.performSDPQuery(self)
                    log("performSDPQuery returned 0x\(String(UInt32(bitPattern: r), radix: 16))")
                }
            case "rfcomm": rawRFCOMM(arg ?? "")
            case "raw": if let a = arg { rawSend(a) }
            case "rawclose": rawChannel?.close(); log("raw channel closed")
            case "remap":
                // arg: "<from> <to>", for example "1 3"; "0 0" turns it off
                let p = (arg ?? "").split(separator: " ").compactMap { UInt8($0) }
                if p.count == 2 { rfcommRemapFrom = p[0]; rfcommRemapTo = p[1]; log("RFCOMM remap \(p[0]) -> \(p[1])") }
            case "publish-hf": publishHF()
            case "hfsco":
                // Ask Apple's hands-free class to open the voice link without an HFP service level connection.
                if hf == nil, let dev = selectDevice(address: arg) { hf = IOBluetoothHandsFreeDevice(device: dev, delegate: self) }
                log("hf connected=\(hf?.isConnected ?? false); calling connectSCO()")
                hf?.connectSCO()
            case "slc": startSLC()
            case "quit": NSApp.terminate(nil)
            default: log("unknown command")
            }
        }
    }

    // MARK: Raw RFCOMM test (HFP service level connection by hand)

    var rawChannel: IOBluetoothRFCOMMChannel?

    func listServices(address: String?) {
        guard let dev = selectDevice(address: address) else { log("No device"); return }
        for rec in (dev.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            var ch: BluetoothRFCOMMChannelID = 0
            let ok = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            log("SDP service: \(rec.getServiceName() ?? "?") rfcomm=\(ok ? String(ch) : "-")")
        }
        if let ag = dev.handsFreeAudioGatewayServiceRecord() {
            var ch: BluetoothRFCOMMChannelID = 0
            ag.getRFCOMMChannelID(&ch)
            log("HFP AG RFCOMM channel: \(ch)")
        }
    }

    @objc func sdpQueryComplete(_ dev: IOBluetoothDevice!, status: IOReturn) {
        log("SDP query complete status=0x\(String(UInt32(bitPattern: status), radix: 16))")
        for rec in (dev.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            var ch: BluetoothRFCOMMChannelID = 0
            let ok = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
            let classes = (rec.getAttributeDataElement(1)?.getArrayValue() as? [IOBluetoothSDPDataElement])?
                .compactMap { $0.getUUIDValue().map { $0.map { String(format: "%02x", $0) }.joined() } } ?? []
            log("SDP fresh: \(rec.getServiceName() ?? "?") rfcomm=\(ok ? String(ch) : "-") classes=\(classes)")
        }
    }

    // arg: "<address> <channel>"
    func rawRFCOMM(_ arg: String) {
        let p = arg.split(separator: " ").map(String.init)
        guard p.count == 2, let dev = IOBluetoothDevice(addressString: p[0]), let ch = UInt8(p[1]) else { log("usage: rfcomm <address> <channel>"); return }
        hf?.disconnect()
        var chan: IOBluetoothRFCOMMChannel?
        let r = dev.openRFCOMMChannelAsync(&chan, withChannelID: ch, delegate: self)
        rawChannel = chan
        log("openRFCOMMChannelAsync(channel \(ch)) returned 0x\(String(UInt32(bitPattern: r), radix: 16))")
    }

    func rawSend(_ s: String) {
        guard let c = rawChannel else { log("no raw channel"); return }
        var bytes = Array((s + "\r").utf8)
        let r = c.writeSync(&bytes, length: UInt16(bytes.count))
        log("raw > \(s)  (write 0x\(String(UInt32(bitPattern: r), radix: 16)))")
    }

    @objc func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        log("RAW RFCOMM open complete status=0x\(String(UInt32(bitPattern: status), radix: 16)) mtu=\(c?.getMTU() ?? 0)")
    }
    @objc func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        let s = String(decoding: UnsafeRawBufferPointer(start: data, count: length), as: UTF8.self)
        log("raw < " + s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))
        if slcStep > 0 && s.contains("OK") { advanceSLC() }
        if s.contains("ERROR") && slcStep > 0 { log("SLC step \(slcStep) got ERROR"); slcStep = 0 }
    }

    // MARK: Publish a Hands-Free SDP record so the phone sees the Mac as a hands-free unit

    var hfRecord: IOBluetoothSDPServiceRecord?
    var incomingNote: IOBluetoothUserNotification?

    func uuid16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    func uint(_ v: Int, size: Int) -> [String: Any] { ["DataElementType": 1, "DataElementSize": size, "DataElementValue": v] }

    func publishHF() {
        if hfRecord != nil { log("HF record already published"); return }
        let dict: [String: Any] = [
            "0001 - ServiceClassIDList": [uuid16(0x111E), uuid16(0x1203)],
            "0004 - ProtocolDescriptorList": [[uuid16(0x0100)], [uuid16(0x0003), uint(10, size: 1)]],
            "0005 - BrowseGroupList*": [uuid16(0x1002)],
            "0009 - BluetoothProfileDescriptorList": [[uuid16(0x111E), uint(0x0107, size: 2)]],
            "0100 - ServiceName*": "HFP Probe Hands-Free",
            "0311 - SupportedFeatures": uint(0x0014, size: 2),
        ]
        guard let rec = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: dict) else { log("publishedServiceRecord returned nil"); return }
        hfRecord = rec
        var ch: BluetoothRFCOMMChannelID = 0
        rec.getRFCOMMChannelID(&ch)
        log("Published HF SDP record on local RFCOMM channel \(ch)")
        incomingNote = IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications: self,
            selector: #selector(incomingRFCOMM(_:channel:)), withChannelID: ch,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming)
    }

    @objc func incomingRFCOMM(_ note: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        log("INCOMING RFCOMM from \(channel.getDevice()?.name ?? "?") on channel \(channel.getID())")
        rawChannel = channel
        channel.setDelegate(self)
        startSLC()
    }

    // MARK: HFP service level connection by hand (HF side)

    var slcStep = 0
    let slcCommands = ["AT+BRSF=20", "AT+CIND=?", "AT+CIND?", "AT+CMER=3,0,0,1", "AT+CLIP=1"]

    func startSLC() { slcStep = 1; log("Starting SLC"); rawSend(slcCommands[0]) }

    func advanceSLC() {
        if slcStep >= slcCommands.count { log("SLC COMPLETE. Phone accepted the Mac as a hands-free unit."); slcStep = 0; return }
        rawSend(slcCommands[slcStep]); slcStep += 1
    }
    @objc func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) { log("RAW RFCOMM closed") }

    // MARK: Audio device changes

    func watchAudioDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            guard let self else { return }
            let now = audioDevices()
            let added = now.filter { !self.lastAudio.contains($0) }
            let removed = self.lastAudio.filter { !now.contains($0) }
            if !added.isEmpty { self.log("Audio device ADDED: " + added.joined(separator: "; ")) }
            if !removed.isEmpty { self.log("Audio device REMOVED: " + removed.joined(separator: "; ")) }
            self.lastAudio = now
        }
    }

    // MARK: IOBluetoothHandsFreeDelegate

    @objc(handsFree:connected:) func hfConnected(_ d: IOBluetoothHandsFree, connected s: NSNumber) {
        log("EVENT connected status=\(s) (0 = success)")
        status()
    }
    @objc(handsFree:disconnected:) func hfDisconnected(_ d: IOBluetoothHandsFree, disconnected s: NSNumber) { log("EVENT disconnected status=\(s)") }
    @objc(handsFree:scoConnectionOpened:) func hfSCOOpened(_ d: IOBluetoothHandsFree, scoConnectionOpened s: NSNumber) {
        log("EVENT SCO opened status=\(s)")
        listAudio()
    }
    @objc(handsFree:scoConnectionClosed:) func hfSCOClosed(_ d: IOBluetoothHandsFree, scoConnectionClosed s: NSNumber) { log("EVENT SCO closed status=\(s)") }

    // MARK: IOBluetoothHandsFreeDeviceDelegate

    @objc(handsFree:isServiceAvailable:) func hfService(_ d: IOBluetoothHandsFreeDevice, isServiceAvailable v: NSNumber) { log("EVENT service=\(v)") }
    @objc(handsFree:isCallActive:) func hfCall(_ d: IOBluetoothHandsFreeDevice, isCallActive v: NSNumber) { log("EVENT callActive=\(v)") }
    @objc(handsFree:callSetupMode:) func hfSetup(_ d: IOBluetoothHandsFreeDevice, callSetupMode v: NSNumber) {
        let names = ["none", "incoming", "outgoing dialing", "outgoing alerting"]
        log("EVENT callSetup=\(v) (\(v.intValue < names.count ? names[v.intValue] : "?"))")
    }
    @objc(handsFree:callHoldState:) func hfHold(_ d: IOBluetoothHandsFreeDevice, callHoldState v: NSNumber) { log("EVENT callHeld=\(v)") }
    @objc(handsFree:signalStrength:) func hfSignal(_ d: IOBluetoothHandsFreeDevice, signalStrength v: NSNumber) { log("EVENT signal=\(v)") }
    @objc(handsFree:isRoaming:) func hfRoam(_ d: IOBluetoothHandsFreeDevice, isRoaming v: NSNumber) { log("EVENT roaming=\(v)") }
    @objc(handsFree:batteryCharge:) func hfBatt(_ d: IOBluetoothHandsFreeDevice, batteryCharge v: NSNumber) { log("EVENT battery=\(v)") }
    @objc(handsFree:incomingCallFrom:) func hfIncoming(_ d: IOBluetoothHandsFreeDevice, incomingCallFrom n: String) { log("EVENT incoming call from \(n)") }
    @objc(handsFree:ringAttempt:) func hfRing(_ d: IOBluetoothHandsFreeDevice, ringAttempt v: NSNumber) { log("EVENT RING #\(v)") }
    @objc(handsFree:currentCall:) func hfCurrent(_ d: IOBluetoothHandsFreeDevice, currentCall c: NSDictionary) { log("EVENT current call: \(c)") }
    @objc(handsFree:subscriberNumber:) func hfSub(_ d: IOBluetoothHandsFreeDevice, subscriberNumber n: String) { log("EVENT subscriber number \(n)") }
    @objc(handsFree:incomingSMS:) func hfSMS(_ d: IOBluetoothHandsFreeDevice, incomingSMS s: NSDictionary) { log("EVENT SMS \(s)") }
    @objc(handsFree:unhandledResultCode:) func hfUnhandled(_ d: IOBluetoothHandsFreeDevice, unhandledResultCode r: String) { log("EVENT unhandled result: \(r)") }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.regular)
app.run()
