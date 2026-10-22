// Plays a looping ringtone on the Mac while an incoming call rings.
// It rings on the current sound output and also on the Mac's built-in speakers,
// so a call is heard even when earphones are the selected output.

import AVFoundation
import AppKit
import Combine
import CoreAudio

final class Ringer: ObservableObject {
    private static let toneDir = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"
    /// Apple's default ringtone on iPhone and in the Mac Phone app.
    static let defaultTone = "Reflection"

    /// Every Apple ringtone on this Mac, by name. Some exist only as an "-EncoreInfinitum" file; the plain file wins when both exist.
    static let toneFiles: [String: String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: toneDir)) ?? []
        var map: [String: String] = [:]
        for f in files.sorted() where f.hasSuffix(".m4r") {
            let base = String(f.dropLast(4))
            let name = base.replacingOccurrences(of: "-EncoreInfinitum", with: "")
            if map[name] == nil || base == name { map[name] = f }
        }
        return map
    }()

    /// The default first, then the classic iPhone ringtone, then the rest by name.
    static let tones: [String] = {
        let rest = toneFiles.keys.filter { $0 != defaultTone && $0 != "Opening" }.sorted()
        return [defaultTone, "Opening"].filter { toneFiles[$0] != nil } + rest
    }()

    static func label(_ tone: String) -> String {
        tone == defaultTone ? "\(tone) (Default)" : tone == "Opening" ? "Opening (Classic iPhone)" : tone
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "ringtoneEnabled"); if !enabled { stop() } }
    }
    @Published var tone: String {
        didSet { UserDefaults.standard.set(tone, forKey: "ringtoneName"); if !players.isEmpty { start() } }
    }
    @Published var useSpeakers: Bool {
        didSet { UserDefaults.standard.set(useSpeakers, forKey: "ringOnSpeakers") }
    }

    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []
    private var fallback: NSSound?
    private var cancellable: AnyCancellable?

    init(engine: CallEngine) {
        enabled = UserDefaults.standard.object(forKey: "ringtoneEnabled") as? Bool ?? true
        tone = UserDefaults.standard.string(forKey: "ringtoneName") ?? Self.defaultTone
        useSpeakers = UserDefaults.standard.object(forKey: "ringOnSpeakers") as? Bool ?? true
        cancellable = engine.$phase.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] phase in
            if phase == .incoming { self?.start() } else { self?.stop() }
        }
    }

    func start() {
        guard enabled else { return }
        stop()
        guard let file = Self.toneFiles[tone] ?? Self.toneFiles[Self.defaultTone] else {
            // The tone library is not part of the public SDK; fall back to a built-in system sound.
            appLog("ringtone \(tone) missing, using Glass")
            if let s = NSSound(named: "Glass") { s.loops = true; s.play(); fallback = s }
            return
        }
        let url = URL(fileURLWithPath: "\(Self.toneDir)/\(file)")
        var outputs: [String?] = [nil]  // nil = the current sound output
        if useSpeakers, let speakers = Self.builtInSpeakersUID(), speakers != Self.defaultOutputUID() {
            outputs.append(speakers)
        }
        for uid in outputs {
            let p = AVQueuePlayer()
            p.audioOutputDeviceUniqueID = uid
            loopers.append(AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url)))
            players.append(p)
            p.play()
        }
        appLog("ringtone \(tone) playing on \(outputs.map { $0 ?? "current output" })")
    }

    /// Plays the chosen tone for 3 seconds, for the menu preview.
    func preview() {
        start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.stop() }
    }

    func stop() {
        players.forEach { $0.pause() }
        players = []
        loopers = []
        fallback?.stop()
        fallback = nil
    }

    // MARK: Core Audio lookups

    private static func uid(of id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return uid(of: id)
    }

    /// The built-in output that has output streams (the Mac mini Speakers).
    private static func builtInSpeakersUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &t, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var s = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                               mScope: kAudioObjectPropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &s, 0, nil, &ssize) == noErr, ssize > 0 { return uid(of: id) }
        }
        return nil
    }
}
