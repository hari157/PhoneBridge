// Floating call panel at the top right of the screen, shown while a call rings or is active.

import AppKit
import Combine
import SwiftUI

struct CallPanelView: View {
    @EnvironmentObject var engine: CallEngine
    @EnvironmentObject var contacts: ContactsStore
    @StateObject private var keys = Box(false)

    private var name: String? { engine.number.isEmpty ? nil : contacts.name(for: engine.number) }
    private var title: String { name ?? (engine.number.isEmpty ? "Unknown Caller" : formatNumber(engine.number)) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Avatar(name: name, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    status.font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            if keys.value && engine.phase == .active {
                VStack(spacing: 10) {
                    // The digits sent so far; the newest stay visible when the line is full.
                    Text(engine.sentDigits.isEmpty ? "Press a number" : engine.sentDigits)
                        .font(engine.sentDigits.isEmpty ? .callout : .system(size: 26, weight: .medium, design: .rounded))
                        .foregroundStyle(engine.sentDigits.isEmpty ? .tertiary : .primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: engine.sentDigits)
                    Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                        ForEach(KeypadView.keys.indices, id: \.self) { r in
                            GridRow {
                                ForEach(KeypadView.keys[r].indices, id: \.self) { c in
                                    let d = KeypadView.keys[r][c].0
                                    Button { engine.sendDigit(d) } label: {
                                        Text(d)
                                            .font(.system(size: 18, design: .rounded))
                                            .frame(width: 44, height: 34)
                                    }
                                    .buttonStyle(InCallKeyStyle())
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                switch engine.phase {
                case .incoming:
                    PanelButton(title: "Decline", icon: "phone.down.fill", color: .callRed) { engine.end() }
                    PanelButton(title: "Accept", icon: "phone.fill", color: .callGreen) { engine.answer() }
                case .active:
                    PanelButton(title: "Keypad", icon: "circle.grid.3x3.fill", color: .gray) {
                        withAnimation(.snappy) { keys.value.toggle() }
                    }
                    PanelButton(title: "End", icon: "phone.down.fill", color: .callRed) { engine.end() }
                default:
                    PanelButton(title: "End", icon: "phone.down.fill", color: .callRed) { engine.end() }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "smartphone")
                Text("Voice plays on \(engine.phoneName)")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .onChange(of: engine.phase) { _, p in if p != .active { keys.value = false } }
        .onReceive(NotificationCenter.default.publisher(for: .showInCallKeys)) { _ in keys.value = true }
    }

    @ViewBuilder private var status: some View {
        switch engine.phase {
        case .incoming: Text("Incoming call…")
        case .dialing: Text("Calling…")
        case .alerting: Text("Ringing…")
        case .active:
            if let start = engine.callStart {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(start))),
                         format: .time(pattern: .minuteSecond))
                }
            } else {
                Text("Connected")
            }
        case .idle: Text("Call ended")
        }
    }
}

extension Notification.Name {
    /// Opens the in-call keypad, for the test command file.
    static let showInCallKeys = Notification.Name("PhoneBridgeShowInCallKeys")
}

/// A keypad key that lights up while it is pressed.
struct InCallKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.28 : 0.08), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(color.gradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Owns the borderless floating panel and shows it whenever the phone has a call.
final class CallPanelController {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?

    init(engine: CallEngine, contacts: ContactsStore) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CallPanelView().environmentObject(engine).environmentObject(contacts))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host

        cancellable = engine.$phase.removeDuplicates().receive(on: RunLoop.main).sink { [weak self, weak engine] phase in
            guard let self else { return }
            self.pendingShow?.cancel()
            // A call the phone starts by itself may be a one-second phantom, so wait before showing it.
            if (phase == .dialing || phase == .alerting), !self.panel.isVisible, engine?.startedOnMac == false {
                let show = DispatchWorkItem { [weak self] in self?.update(visible: true) }
                self.pendingShow = show
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: show)
                return
            }
            self.update(visible: phase != .idle)
        }
    }

    private var pendingShow: DispatchWorkItem?

    var window: NSWindow { panel }

    private func update(visible: Bool) {
        guard visible else { panel.orderOut(nil); return }
        panel.layoutIfNeeded()
        if !panel.isVisible, let screen = NSScreen.main {
            let size = panel.contentView?.fittingSize ?? panel.frame.size
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }
}
