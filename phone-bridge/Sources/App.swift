// PhoneBridge: control Android phone calls from the Mac.
// Test commands can be written one per line to ~/Library/Logs/PhoneBridge/cmd.txt.

import AppKit
import SwiftUI

let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PhoneBridge")

func appLog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let url = logDir.appendingPathComponent("app.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class AppModel {
    static let shared = AppModel()
    let engine = CallEngine()
    let recents = RecentsStore()
    let contacts = ContactsStore()
    let ui = UIState()
    lazy var ringer = Ringer(engine: engine)
}

struct RingtoneCommands: Commands {
    @ObservedObject var ringer: Ringer

    var body: some Commands {
        CommandMenu("Ringtone") {
            Toggle("Play Ringtone on Mac", isOn: $ringer.enabled)
            Toggle("Also Ring on Mac Speakers", isOn: $ringer.useSpeakers)
            Divider()
            Picker("Tone", selection: $ringer.tone) {
                ForEach(Ringer.tones, id: \.self) { Text(Ringer.label($0)) }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Preview Ringtone") { ringer.preview() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: CallPanelController?
    private var commandTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let m = AppModel.shared
        m.engine.log = appLog
        m.engine.onCallEnded = { m.recents.add($0) }
        panel = CallPanelController(engine: m.engine, contacts: m.contacts)
        _ = m.ringer
        m.contacts.load()
        m.engine.start()
        appLog("PhoneBridge started")

        let cmdURL = logDir.appendingPathComponent("cmd.txt")
        try? "".write(to: cmdURL, atomically: true, encoding: .utf8)
        commandTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let text = try? String(contentsOf: cmdURL, encoding: .utf8), !text.isEmpty else { return }
            try? "".write(to: cmdURL, atomically: true, encoding: .utf8)
            for line in text.split(separator: "\n") { self?.run(String(line)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        // tel: links from Contacts, Safari, and Calendar
        for url in urls where url.scheme == "tel" {
            let n = url.absoluteString.dropFirst(4).removingPercentEncoding ?? ""
            AppModel.shared.ui.keypadNumber = n.filter { "0123456789+*#".contains($0) }
            AppModel.shared.ui.section = .keypad
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let m = AppModel.shared
        appLog("cmd: \(line)")
        switch parts.first ?? "" {
        case "dial": m.engine.dial(arg)
        case "answer": m.engine.answer()
        case "end": m.engine.end()
        case "select": m.ui.section = Section(rawValue: arg.capitalized)
        case "keypad": m.ui.keypadNumber = arg
        case "demo":
            let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
            let phase: CallPhase = ["incoming": .incoming, "dialing": .dialing, "alerting": .alerting, "active": .active][p.first ?? ""] ?? .idle
            m.engine.demo(phase, number: p.count > 1 ? p[1] : "")
        case "demo-recents":
            let now = Date()
            m.recents.add(CallRecord(number: "+15555550101", direction: .missed, date: now.addingTimeInterval(-86_400 * 2), duration: 0))
            m.recents.add(CallRecord(number: "+15555550102", direction: .incoming, date: now.addingTimeInterval(-7_200), duration: 312))
            m.recents.add(CallRecord(number: "+15555550101", direction: .outgoing, date: now.addingTimeInterval(-600), duration: 11))
        case "clear-recents": m.recents.clear()
        case "add-recent":
            // Inserts a call at the top while the window is open, to check the list layout.
            m.recents.add(CallRecord(number: arg.isEmpty ? "+15555550103" : arg, direction: .incoming, date: Date(), duration: 30))
        case "ringer": appLog("ringer enabled=\(m.ringer.enabled) tone=\(m.ringer.tone) choices=\(Ringer.tones.count) first=\(Ringer.tones.prefix(4))")
        case "tone": m.ringer.tone = arg; m.ringer.preview()
        case "snapshot": snapshot(name: arg.isEmpty ? "window" : arg)
        case "snapshot-sidebar":
            // The real sidebar uses a translucent material that cacheDisplay cannot draw, so draw its content on a plain background.
            let content = VStack(alignment: .leading, spacing: 10) {
                ForEach(Section.allCases) { s in Label(s.rawValue, systemImage: s.icon) }
                Spacer()
                PhoneStatusCard()
            }
            .padding(12)
            .frame(width: 230, height: 420)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(m.engine)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 230, height: 420)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: logDir.appendingPathComponent("snap-sidebar.png"))
                appLog("snapshot snap-sidebar.png")
            }
        case "connect": m.engine.connect()
        case "panel-keys": NotificationCenter.default.post(name: .showInCallKeys, object: nil)
        case "digit": arg.forEach { m.engine.sendDigit(String($0)) }
        case "indicator":
            // "indicator 2" = dialing, "indicator 3" = alerting, "indicator 0" = idle, "indicator active" = call up
            m.engine.simulate(setup: Int(arg) ?? 0, active: arg == "active")
        case "status": appLog("link=\(m.engine.link) handsFreeUp=\(m.engine.handsFreeUp) phase=\(m.engine.phase) signal=\(m.engine.signal) battery=\(m.engine.battery) number=\(m.engine.number)")
        case "quit": NSApp.terminate(nil)
        default: appLog("unknown command")
        }
    }

    /// Renders the main window and the call panel to PNG files in the log folder.
    private func snapshot(name: String) {
        for (i, w) in NSApp.windows.enumerated() where w.isVisible {
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let file = logDir.appendingPathComponent("snap-\(name)-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            appLog("snapshot \(file.lastPathComponent) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }
}

@main
struct PhoneBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("PhoneBridge", id: "main") {
            RootView()
                .environmentObject(AppModel.shared.engine)
                .environmentObject(AppModel.shared.recents)
                .environmentObject(AppModel.shared.contacts)
                .environmentObject(AppModel.shared.ui)
        }
        .defaultSize(width: 880, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reconnect Phone") { AppModel.shared.engine.connect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            RingtoneCommands(ringer: AppModel.shared.ringer)
        }
    }
}
