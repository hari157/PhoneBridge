// Main window in the style of the macOS Phone app: sidebar, recents, contacts, keypad.

import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case calls = "Calls", contacts = "Contacts", keypad = "Keypad"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .calls: "clock"
        case .contacts: "person.crop.circle"
        case .keypad: "circle.grid.3x3"
        }
    }
}

/// View-local state. Used in place of @State, which needs the SwiftUI macro plugin that only Xcode ships.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

final class UIState: ObservableObject {
    @Published var section: Section? = .calls
    @Published var keypadNumber = ""
}

// MARK: - Shared pieces

extension Color {
    static let callGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let callRed = Color(red: 1.0, green: 0.23, blue: 0.19)
}

func formatNumber(_ n: String) -> String {
    let digits = n.filter(\.isNumber)
    if n.hasPrefix("+91"), digits.count == 12 {
        let d = Array(digits.dropFirst(2))
        return "+91 \(String(d[0..<5])) \(String(d[5...]))"
    }
    if digits.count == 10, !n.hasPrefix("+") {
        let d = Array(digits)
        return "\(String(d[0..<5])) \(String(d[5...]))"
    }
    return n
}

struct Avatar: View {
    let name: String?
    var size: CGFloat = 36

    private var initials: String {
        guard let name else { return "" }
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }.prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        let h = (name ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(
                name == nil
                    ? AnyShapeStyle(Color.gray.gradient)
                    : AnyShapeStyle(tint.gradient)
            )
            if name == nil || initials.isEmpty || initials.first?.isNumber == true || initials.first == "+" {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

struct RoundCallButton: View {
    var size: CGFloat = 28
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.callGreen))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help("Call")
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var ui: UIState

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.section) {
                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.icon).tag(s)
                }
            }
            .safeAreaInset(edge: .bottom) { PhoneStatusCard().padding(10) }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            switch ui.section ?? .calls {
            case .calls: RecentsView()
            case .contacts: ContactsView()
            case .keypad: KeypadView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

// MARK: - Phone status

/// The paired phones, for the sidebar menu and the Phone menu in the menu bar.
struct PhonePickerItems: View {
    @EnvironmentObject var engine: CallEngine

    var body: some View {
        if engine.phones.isEmpty {
            Text("No paired phones. Pair one in System Settings > Bluetooth.")
        }
        ForEach(engine.phones) { p in
            Button {
                engine.switchPhone(to: p.id)
            } label: {
                if p.id == engine.phoneAddress {
                    Label(p.name, systemImage: "checkmark")
                } else {
                    Text(p.connected ? "\(p.name)  ●" : p.name)
                }
            }
            .disabled(!engine.canSwitchPhone)
        }
        Divider()
        Button("Refresh List") { engine.refreshPhones() }
        Button("Bluetooth Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        }
    }
}

struct PhoneStatusCard: View {
    @EnvironmentObject var engine: CallEngine

    private var statusText: String {
        switch engine.link {
        case .connected: engine.hasService ? "Connected" : "Connected · No service"
        case .connecting: "Connecting…"
        case .searching: "Looking for phone…"
        case .failed(let r): r
        }
    }

    private var statusColor: Color {
        switch engine.link {
        case .connected: .green
        case .connecting, .searching: .orange
        case .failed: .red
        }
    }

    private var batteryIcon: String {
        switch engine.battery {
        case ..<1: "battery.0percent"
        case 1: "battery.25percent"
        case 2, 3: "battery.50percent"
        case 4: "battery.75percent"
        default: "battery.100percent"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "smartphone")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        PhonePickerItems()
                    } label: {
                        Text(engine.phoneName).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose which phone PhoneBridge uses")
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if engine.link == .connected {
                HStack(spacing: 12) {
                    Image(systemName: "cellularbars", variableValue: Double(engine.signal) / 5)
                    Image(systemName: batteryIcon)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 34)
            } else if case .failed = engine.link {
                Button("Try Again") { engine.connect() }
                    .controlSize(.small)
                    .padding(.leading, 34)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Recents

struct RecentsView: View {
    @EnvironmentObject var recents: RecentsStore
    @EnvironmentObject var engine: CallEngine

    var body: some View {
        Group {
            if recents.calls.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Calls", systemImage: "phone")
                } description: {
                    Text("Calls you make or answer with your Android phone appear here.")
                }
            } else {
                // A plain stack, not List: List (NSTableView) keeps the old row height when a call is
                // inserted at the top while the window is open, and the rows then draw on top of each other.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(recents.calls) { call in
                            RecentRow(call: call)
                                .padding(.horizontal, 16)
                                .contextMenu {
                                    Button("Call Back") { engine.dial(call.number) }
                                    Button("Copy Number") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(call.number, forType: .string)
                                    }
                                    Divider()
                                    Button("Delete from Recents", role: .destructive) { recents.remove(call) }
                                }
                            Divider().padding(.leading, 64)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Calls")
        .toolbar {
            if !recents.calls.isEmpty {
                Button("Clear", systemImage: "trash") { recents.clear() }
                    .help("Clear all recent calls")
            }
        }
    }
}

struct RecentRow: View {
    let call: CallRecord
    @EnvironmentObject var engine: CallEngine
    @EnvironmentObject var contacts: ContactsStore
    @StateObject private var hover = Box(false)

    private var name: String? { contacts.name(for: call.number) }

    private var detail: (icon: String, text: String) {
        switch call.direction {
        case .outgoing: ("phone.arrow.up.right", "Outgoing")
        case .incoming: ("phone.arrow.down.left", "Incoming")
        case .missed: ("phone.arrow.down.left", "Missed")
        }
    }

    private var durationText: String {
        guard call.duration >= 1 else { return "" }
        let s = Int(call.duration)
        return s >= 60 ? " · \(s / 60) min \(s % 60) s" : " · \(s) s"
    }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? formatNumber(call.number))
                    .font(.body.weight(.medium))
                    .foregroundStyle(call.direction == .missed ? Color.callRed : .primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: detail.icon)
                    Text(detail.text + durationText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(call.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
            RoundCallButton(disabled: !engine.canCall) { engine.dial(call.number) }
                .opacity(hover.value ? 1 : 0)
        }
        .frame(height: 44)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture(count: 2) { engine.dial(call.number) }
    }
}

// MARK: - Contacts

struct ContactsView: View {
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var engine: CallEngine
    @StateObject private var search = Box("")

    private var filtered: [ContactItem] {
        guard !search.value.isEmpty else { return contacts.contacts }
        let q = search.value.lowercased()
        return contacts.contacts.filter { c in
            c.name.lowercased().contains(q) || c.numbers.contains { $0.filter(\.isNumber).contains(q.filter(\.isNumber)) && !q.filter(\.isNumber).isEmpty }
        }
    }

    var body: some View {
        Group {
            switch contacts.access {
            case .denied:
                ContentUnavailableView {
                    Label("Contacts Not Allowed", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Allow PhoneBridge to read your contacts to see names for calls.")
                } actions: {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            case .unknown:
                ProgressView()
            case .granted where contacts.contacts.isEmpty:
                ContentUnavailableView("No Contacts", systemImage: "person.2", description: Text("Contacts with phone numbers appear here."))
            case .granted:
                List(filtered) { c in
                    ContactRow(contact: c)
                }
                .listStyle(.inset)
                .searchable(text: $search.value, prompt: "Search contacts")
            }
        }
        .navigationTitle("Contacts")
    }
}

struct ContactRow: View {
    let contact: ContactItem
    @EnvironmentObject var engine: CallEngine
    @StateObject private var hover = Box(false)

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: contact.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name).font(.body.weight(.medium)).lineLimit(1)
                Text(formatNumber(contact.numbers[0])).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if contact.numbers.count > 1 {
                Menu {
                    ForEach(contact.numbers, id: \.self) { n in
                        Button(formatNumber(n)) { engine.dial(n) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .opacity(hover.value ? 1 : 0)
            }
            RoundCallButton(disabled: !engine.canCall) { engine.dial(contact.numbers[0]) }
                .opacity(hover.value ? 1 : 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture(count: 2) { engine.dial(contact.numbers[0]) }
    }
}

// MARK: - Keypad

struct KeypadView: View {
    @EnvironmentObject var engine: CallEngine
    @EnvironmentObject var contacts: ContactsStore
    @EnvironmentObject var ui: UIState
    @FocusState private var focused: Bool

    static let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(spacing: 4) {
                Text(ui.keypadNumber.isEmpty ? " " : formatNumber(ui.keypadNumber))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(height: 44)
                Text(contacts.name(for: ui.keypadNumber) ?? " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            Grid(horizontalSpacing: 24, verticalSpacing: 14) {
                ForEach(0..<4, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { c in
                            let key = Self.keys[r][c]
                            KeyButton(digit: key.0, letters: key.1) { press(key.0) } onLongPress: {
                                if key.0 == "0" { press("+") }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 24) {
                Color.clear.frame(width: 70, height: 70)
                RoundCallButton(size: 70, disabled: !engine.canCall || ui.keypadNumber.isEmpty) {
                    engine.dial(ui.keypadNumber)
                }
                .keyboardShortcut(.return, modifiers: [])
                Button {
                    if !ui.keypadNumber.isEmpty { ui.keypadNumber.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, height: 70)
                }
                .buttonStyle(.plain)
                .opacity(ui.keypadNumber.isEmpty ? 0 : 1)
                .help("Delete")
            }
            .padding(.top, 16)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Keypad")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(characters: CharacterSet(charactersIn: "0123456789*#+")) { k in
            press(k.characters)
            return .handled
        }
        .onKeyPress(.delete) {
            if !ui.keypadNumber.isEmpty { ui.keypadNumber.removeLast() }
            return .handled
        }
        .onCommand(#selector(NSText.paste(_:))) {
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            ui.keypadNumber += pasted.filter { "0123456789+*#".contains($0) }
        }
    }

    private func press(_ s: String) {
        if engine.phase == .active { engine.sendDigit(s) }
        if ui.keypadNumber.count < 20 { ui.keypadNumber += s }
    }
}

struct KeyButton: View {
    let digit: String
    let letters: String
    let onTap: () -> Void
    var onLongPress: () -> Void = {}
    @StateObject private var hover = Box(false)
    @GestureState private var pressing = false

    var body: some View {
        VStack(spacing: 0) {
            Text(digit)
                .font(.system(size: digit == "*" ? 34 : 28, weight: .regular, design: .rounded))
                .offset(y: digit == "*" ? 5 : 0)
            Text(letters.isEmpty ? " " : letters)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
        }
        .frame(width: 70, height: 70)
        .background(Circle().fill(Color.primary.opacity(pressing ? 0.22 : hover.value ? 0.12 : 0.07)))
        .contentShape(Circle())
        .onHover { hover.value = $0 }
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
                .exclusively(before: TapGesture().onEnded { onTap() })
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true }
        )
    }
}
