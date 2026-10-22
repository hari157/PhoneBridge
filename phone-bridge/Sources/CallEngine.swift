// Call control for an Android phone over Bluetooth HFP, using the public IOBluetoothHandsFreeDevice.
// Call audio stays on the phone: macOS 27 refuses SCO for third-party apps.

import Foundation
import IOBluetooth

// MARK: - Channel remap
// Some phones (OnePlus 7T) advertise their HFP gateway on one RFCOMM channel but listen on another.
// These swaps let IOBluetoothHandsFreeDevice open the channel that really answers. They act only in this process.

var rfcommRemapFrom: BluetoothRFCOMMChannelID = 0
var rfcommRemapTo: BluetoothRFCOMMChannelID = 0

extension IOBluetoothDevice {
    @objc dynamic func pb_openRFCOMMChannelAsync(_ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!,
                                                 withChannelID id: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        let target = (rfcommRemapTo != 0 && id == rfcommRemapFrom) ? rfcommRemapTo : id
        return pb_openRFCOMMChannelAsync(channel, withChannelID: target, delegate: delegate)
    }
    @objc dynamic func pb_openRFCOMMChannelSync(_ channel: AutoreleasingUnsafeMutablePointer<IOBluetoothRFCOMMChannel?>!,
                                                withChannelID id: BluetoothRFCOMMChannelID, delegate: Any!) -> IOReturn {
        let target = (rfcommRemapTo != 0 && id == rfcommRemapFrom) ? rfcommRemapTo : id
        return pb_openRFCOMMChannelSync(channel, withChannelID: target, delegate: delegate)
    }
}

extension IOBluetoothSDPServiceRecord {
    @objc dynamic func pb_getRFCOMMChannelID(_ p: UnsafeMutablePointer<BluetoothRFCOMMChannelID>!) -> IOReturn {
        let r = pb_getRFCOMMChannelID(p)
        if rfcommRemapTo != 0, r == kIOReturnSuccess, p.pointee == rfcommRemapFrom { p.pointee = rfcommRemapTo }
        return r
    }
}

private var swizzled = false

func installRemapSwizzles() {
    guard !swizzled else { return }
    swizzled = true
    func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        if let m1 = class_getInstanceMethod(cls, a), let m2 = class_getInstanceMethod(cls, b) { method_exchangeImplementations(m1, m2) }
    }
    swap(IOBluetoothDevice.self, #selector(IOBluetoothDevice.openRFCOMMChannelAsync(_:withChannelID:delegate:)),
         #selector(IOBluetoothDevice.pb_openRFCOMMChannelAsync(_:withChannelID:delegate:)))
    swap(IOBluetoothDevice.self, #selector(IOBluetoothDevice.openRFCOMMChannelSync(_:withChannelID:delegate:)),
         #selector(IOBluetoothDevice.pb_openRFCOMMChannelSync(_:withChannelID:delegate:)))
    swap(IOBluetoothSDPServiceRecord.self, #selector(IOBluetoothSDPServiceRecord.getRFCOMMChannelID(_:)),
         #selector(IOBluetoothSDPServiceRecord.pb_getRFCOMMChannelID(_:)))
}

// MARK: - Finding the channel that really answers HFP

/// Opens each candidate RFCOMM channel, sends AT+BRSF, and reports the first channel that answers +BRSF.
final class HFPChannelFinder: NSObject {
    private let device: IOBluetoothDevice
    private var candidates: [BluetoothRFCOMMChannelID]
    private var channel: IOBluetoothRFCOMMChannel?
    private var current: BluetoothRFCOMMChannelID = 0
    private var timer: Timer?
    private var buffer = ""
    private var completion: ((BluetoothRFCOMMChannelID?) -> Void)?

    init(device: IOBluetoothDevice, candidates: [BluetoothRFCOMMChannelID]) {
        self.device = device
        self.candidates = candidates
    }

    func start(_ completion: @escaping (BluetoothRFCOMMChannelID?) -> Void) {
        self.completion = completion
        next()
    }

    private func next() {
        timer?.invalidate()
        channel?.close()
        channel = nil
        buffer = ""
        guard completion != nil else { return }
        guard !candidates.isEmpty else { finish(nil); return }
        current = candidates.removeFirst()
        let savedTo = rfcommRemapTo
        rfcommRemapTo = 0
        var ch: IOBluetoothRFCOMMChannel?
        let r = device.openRFCOMMChannelAsync(&ch, withChannelID: current, delegate: self)
        rfcommRemapTo = savedTo
        guard r == kIOReturnSuccess else { DispatchQueue.main.async { self.next() }; return }
        channel = ch
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.next() }
    }

    /// Stops the search without calling the completion, for a switch to another phone.
    func cancel() {
        completion = nil
        timer?.invalidate()
        channel?.close()
        channel = nil
    }

    private func finish(_ found: BluetoothRFCOMMChannelID?) {
        timer?.invalidate()
        channel?.close()
        channel = nil
        let done = completion
        completion = nil
        done?(found)
    }

    @objc func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard status == kIOReturnSuccess, let c else { next(); return }
        var bytes = Array("AT+BRSF=0\r".utf8)
        _ = c.writeSync(&bytes, length: UInt16(bytes.count))
    }

    @objc func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer += String(decoding: UnsafeRawBufferPointer(start: data, count: length), as: UTF8.self)
        if buffer.contains("+BRSF") { finish(current) } else if buffer.contains("ERROR") { next() }
    }

    @objc func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) {}
}

// MARK: - Call engine

enum CallPhase: Equatable {
    case idle, incoming, dialing, alerting, active
}

enum LinkState: Equatable {
    case searching, connecting, connected, failed(String)
}

/// A phone paired with the Mac that PhoneBridge can connect to.
struct PairedPhone: Identifiable, Hashable {
    let id: String  // Bluetooth address
    let name: String
    let connected: Bool
}

struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case incoming, outgoing, missed }
    var id = UUID()
    var number: String
    var direction: Direction
    var date: Date
    var duration: TimeInterval
}

final class CallEngine: NSObject, ObservableObject {
    @Published var link: LinkState = .searching
    @Published var phoneName = "Phone"
    @Published var phoneAddress = ""
    @Published var phones: [PairedPhone] = []
    @Published var signal = 0
    @Published var battery = 0
    @Published var hasService = false
    @Published var phase: CallPhase = .idle
    @Published var number = ""
    @Published var callStart: Date?

    var onCallEnded: ((CallRecord) -> Void)?
    var log: (String) -> Void = { _ in }

    private var hf: IOBluetoothHandsFreeDevice?
    private var device: IOBluetoothDevice?
    private var finder: HFPChannelFinder?
    private var connectTimer: Timer?
    private var reconnectTimer: Timer?
    private var searchedThisRound = false

    private var callSetup = 0
    private var callActive = false
    private var dialedOut = false
    private var wasActive = false
    private var callBegan = Date()
    private var startedAs: CallPhase = .idle
    private var demoMode = false

    /// True while a call the Mac dialed is being set up.
    var startedOnMac: Bool { dialedOut }

    // MARK: Connection

    private var watchdog: Timer?

    var handsFreeUp: Bool { hf?.isConnected ?? false }

    func start() {
        installRemapSwizzles()
        connect()
        // The phone can drop the control link without a disconnect callback; the app then shows Connected but commands go nowhere.
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshPhones()
            guard let self, !self.demoMode, self.link == .connected, self.phase == .idle, !self.handsFreeUp else { return }
            self.linkLost("hands-free link dropped without notice")
        }
    }

    private func linkLost(_ reason: String) {
        log("link lost: \(reason)")
        callSetup = 0
        callActive = false
        dialedOut = false
        updatePhase()
        link = .connecting
        connect()
    }

    private static func isPhone(_ d: IOBluetoothDevice) -> Bool {
        d.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) || d.handsFreeAudioGatewayServiceRecord() != nil
    }

    /// Reloads the paired phones for the phone picker.
    func refreshPhones() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var seen = Set<String>()  // macOS can list the same phone twice
        phones = paired.filter(Self.isPhone)
            .map { PairedPhone(id: $0.addressString ?? "", name: $0.name ?? "Phone", connected: $0.isConnected()) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var canSwitchPhone: Bool { phase == .idle }

    /// Makes PhoneBridge use another paired phone, and remembers the choice.
    func switchPhone(to address: String) {
        guard canSwitchPhone, address != phoneAddress || link != .connected else { return }
        log("switch phone to \(address)")
        UserDefaults.standard.set(address, forKey: "phoneAddress")
        finder?.cancel()
        finder = nil
        hf?.disconnect()
        hf = nil
        signal = 0
        battery = 0
        hasService = false
        connect()
    }

    private func pickDevice() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if let saved = UserDefaults.standard.string(forKey: "phoneAddress"),
           let d = paired.first(where: { $0.addressString == saved }) { return d }
        let phones = paired.filter { $0.handsFreeAudioGatewayServiceRecord() != nil }
        return phones.first { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) } ?? phones.first
    }

    private func sdpChannel(_ d: IOBluetoothDevice) -> BluetoothRFCOMMChannelID {
        var ch: BluetoothRFCOMMChannelID = 0
        rfcommRemapTo = 0
        _ = d.handsFreeAudioGatewayServiceRecord()?.getRFCOMMChannelID(&ch)
        return ch
    }

    private func channelKey(_ d: IOBluetoothDevice) -> String { "hfpChannel-\(d.addressString ?? "")" }

    private func setRemap(from: BluetoothRFCOMMChannelID, to: BluetoothRFCOMMChannelID) {
        if from == to || to == 0 { rfcommRemapTo = 0 } else { rfcommRemapFrom = from; rfcommRemapTo = to }
    }

    func connect() {
        reconnectTimer?.invalidate()
        connectTimer?.invalidate()
        demoMode = false
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            fail("Bluetooth is off")
            return
        }
        guard let dev = pickDevice() else {
            fail("No paired phone")
            return
        }
        device = dev
        phoneName = dev.name ?? "Phone"
        phoneAddress = dev.addressString ?? ""
        refreshPhones()
        let sdp = sdpChannel(dev)
        if let cached = UserDefaults.standard.object(forKey: channelKey(dev)) as? Int {
            setRemap(from: sdp, to: BluetoothRFCOMMChannelID(cached))
        }
        log("connect \(phoneName) sdpChannel=\(sdp) remap=\(rfcommRemapTo)")
        searchedThisRound = false
        openHandsFree(dev)
    }

    private func openHandsFree(_ dev: IOBluetoothDevice) {
        hf?.disconnect()
        hf = IOBluetoothHandsFreeDevice(device: dev, delegate: self)
        link = .connecting
        hf?.connect()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.connectTimedOut() }
    }

    private func connectTimedOut() {
        guard link != .connected, let dev = device else { return }
        if searchedThisRound {
            UserDefaults.standard.removeObject(forKey: channelKey(dev))
            fail("Phone did not accept the connection")
            return
        }
        searchedThisRound = true
        hf?.disconnect()
        hf = nil
        link = .searching
        let sdp = sdpChannel(dev)
        let candidates = [sdp] + (1...30).map { BluetoothRFCOMMChannelID($0) }.filter { $0 != sdp }
        log("searching for the HFP channel")
        finder = HFPChannelFinder(device: dev, candidates: candidates.filter { $0 != 0 })
        finder?.start { [weak self] found in
            guard let self else { return }
            self.finder = nil
            guard let found else { self.fail("Phone has no hands-free service"); return }
            self.log("HFP answers on channel \(found)")
            UserDefaults.standard.set(Int(found), forKey: self.channelKey(dev))
            self.setRemap(from: sdp, to: found)
            // bluetoothd applies the finder's close a moment later; reopening the same channel at once loses the new link.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard self.device === dev else { return }  // the user switched phones meanwhile
                self.openHandsFree(dev)
            }
        }
    }

    private func fail(_ reason: String) {
        log("link failed: \(reason)")
        link = .failed(reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.connect() }
    }

    // MARK: Actions

    private var dialSentAt = Date.distantPast

    var canCall: Bool { link == .connected && phase == .idle }

    func dial(_ raw: String) {
        let n = raw.filter { "0123456789+*#".contains($0) }
        guard !n.isEmpty, let hf, canCall else { return }
        // A double click or Return plus a click would otherwise send a second ATD before the phone reports dialing.
        guard Date().timeIntervalSince(dialSentAt) > 5 else { log("dial ignored: already dialing"); return }
        dialSentAt = Date()
        number = n
        dialedOut = true
        log("dial \(n)")
        hf.dialNumber(n)
        let sent = dialSentAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.dialSentAt == sent, self.phase == .idle else { return }
            self.dialSentAt = .distantPast
            self.linkLost("phone did not respond to the dial")
        }
    }

    func answer() { log("answer"); hf?.acceptCall() }

    func end() {
        if demoMode { demo(.idle, number: ""); return }
        log("end")
        hf?.endCall()
    }

    /// Digits sent with the in-call keypad during this call, shown above the keys.
    @Published var sentDigits = ""

    func sendDigit(_ d: String) {
        sentDigits += d
        log("keypad \(d)")
        if !demoMode { hf?.sendDTMF(d) }
    }

    // MARK: Call state

    private func updatePhase() {
        let old = phase
        let new: CallPhase
        if callActive { new = .active } else {
            switch callSetup {
            case 1: new = .incoming
            case 2: new = .dialing
            case 3: new = .alerting
            default: new = .idle
            }
        }
        guard new != old else { return }
        log("phase \(old) -> \(new)")
        phase = new
        if new == .idle || old == .idle { sentDigits = "" }
        if old == .idle {
            callBegan = Date()
            wasActive = false
            startedAs = new
            if new == .incoming { dialedOut = false }
            if !dialedOut { number = "" }
            hf?.currentCallList()
        }
        if new == .active && old != .active {
            callStart = Date()
            wasActive = true
            hf?.currentCallList()
        }
        if new == .idle {
            dialSentAt = .distantPast
            // The OnePlus sometimes reports an outgoing call to 10000000 that ends within a second and never connects.
            let phantom = !dialedOut && !wasActive && startedAs != .incoming && Date().timeIntervalSince(callBegan) < 3
            let outgoing = dialedOut || startedAs != .incoming
            let direction: CallRecord.Direction = outgoing ? .outgoing : (wasActive ? .incoming : .missed)
            let duration = callStart.map { Date().timeIntervalSince($0) } ?? 0
            if phantom {
                log("ignored phantom call \(number.isEmpty ? "Unknown" : number)")
            } else {
                onCallEnded?(CallRecord(number: number.isEmpty ? "Unknown" : number, direction: direction, date: callBegan, duration: duration))
            }
            callStart = nil
            dialedOut = false
        }
    }

    /// Feeds a call-setup report through the same path as the phone's, for tests.
    func simulate(setup: Int, active: Bool) {
        callSetup = setup
        callActive = active
        updatePhase()
    }

    /// Shows a call state without a phone, for screenshots of the interface.
    func demo(_ p: CallPhase, number n: String) {
        demoMode = p != .idle
        number = n
        if p != .active { sentDigits = "" }
        phase = p
        callStart = p == .active ? Date().addingTimeInterval(-42) : nil
    }

    // MARK: IOBluetoothHandsFreeDelegate

    @objc(handsFree:connected:) func hfConnected(_ d: IOBluetoothHandsFree, connected s: NSNumber) {
        log("connected status=\(s)")
        guard d === hf, s.intValue == 0 else { return }
        connectTimer?.invalidate()
        link = .connected
        if let a = device?.addressString { UserDefaults.standard.set(a, forKey: "phoneAddress") }
    }

    @objc(handsFree:disconnected:) func hfDisconnected(_ d: IOBluetoothHandsFree, disconnected s: NSNumber) {
        log("disconnected status=\(s)")
        guard d === hf, link == .connected else { return }
        callSetup = 0
        callActive = false
        updatePhase()
        link = .connecting
        scheduleReconnect()
    }

    @objc(handsFree:scoConnectionOpened:) func hfSCOOpened(_ d: IOBluetoothHandsFree, scoConnectionOpened s: NSNumber) {}
    @objc(handsFree:scoConnectionClosed:) func hfSCOClosed(_ d: IOBluetoothHandsFree, scoConnectionClosed s: NSNumber) {}

    // MARK: IOBluetoothHandsFreeDeviceDelegate

    @objc(handsFree:isServiceAvailable:) func hfService(_ d: IOBluetoothHandsFreeDevice, isServiceAvailable v: NSNumber) { hasService = v.boolValue }
    @objc(handsFree:isCallActive:) func hfCall(_ d: IOBluetoothHandsFreeDevice, isCallActive v: NSNumber) { callActive = v.boolValue; updatePhase() }
    @objc(handsFree:callSetupMode:) func hfSetup(_ d: IOBluetoothHandsFreeDevice, callSetupMode v: NSNumber) { callSetup = v.intValue; updatePhase() }
    @objc(handsFree:callHoldState:) func hfHold(_ d: IOBluetoothHandsFreeDevice, callHoldState v: NSNumber) {}
    @objc(handsFree:signalStrength:) func hfSignal(_ d: IOBluetoothHandsFreeDevice, signalStrength v: NSNumber) { signal = v.intValue }
    @objc(handsFree:isRoaming:) func hfRoam(_ d: IOBluetoothHandsFreeDevice, isRoaming v: NSNumber) {}
    @objc(handsFree:batteryCharge:) func hfBattery(_ d: IOBluetoothHandsFreeDevice, batteryCharge v: NSNumber) { battery = v.intValue }
    @objc(handsFree:incomingCallFrom:) func hfIncoming(_ d: IOBluetoothHandsFreeDevice, incomingCallFrom n: String) { if !n.isEmpty { number = n } }
    @objc(handsFree:ringAttempt:) func hfRing(_ d: IOBluetoothHandsFreeDevice, ringAttempt v: NSNumber) {}
    @objc(handsFree:subscriberNumber:) func hfSubscriber(_ d: IOBluetoothHandsFreeDevice, subscriberNumber n: String) {}
    @objc(handsFree:incomingSMS:) func hfSMS(_ d: IOBluetoothHandsFreeDevice, incomingSMS s: NSDictionary) {}
    @objc(handsFree:unhandledResultCode:) func hfUnhandled(_ d: IOBluetoothHandsFreeDevice, unhandledResultCode r: String) {}

    @objc(handsFree:currentCall:) func hfCurrentCall(_ d: IOBluetoothHandsFreeDevice, currentCall c: NSDictionary) {
        if let n = c["number"] as? String, !n.isEmpty { number = n }
        log("call list: number=\(c["number"] ?? "none")")
    }
}
