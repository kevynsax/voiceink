import SwiftUI
import AppKit

@MainActor
final class ServerLogWindowController: NSObject, NSWindowDelegate {
    static let shared = ServerLogWindowController()

    private var window: NSWindow?
    private let windowIdentifier = NSUserInterfaceItemIdentifier("com.prakashjoshipax.voiceink.serverLogWindow")
    private let windowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkServerLogWindowFrame")

    private override init() {
        super.init()
    }

    func show(controller: LocalTranscriptionServerController) {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = ServerLogView(controller: controller)
            .frame(minWidth: 520, minHeight: 360)
        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = String(localized: "Network Server Log")
        window.identifier = windowIdentifier
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)

        window.setFrameAutosaveName(windowAutosaveName)
        if !window.setFrameUsingName(windowAutosaveName) {
            window.center()
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              closing.identifier == windowIdentifier else { return }
        window = nil
    }
}

struct ServerLogView: View {
    @ObservedObject var controller: LocalTranscriptionServerController

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logList
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(controller.statusMessage ?? String(localized: "Server stopped"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button {
                controller.clearLog()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(controller.logEntries.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if controller.logEntries.isEmpty {
                        Text("No activity yet. Requests sent to the server will appear here.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(controller.logEntries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: controller.logEntries.count) { _, _ in
                if let last = controller.logEntries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ entry: LocalTranscriptionServerController.ServerLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(color(for: entry.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for level: LocalTranscriptionServerController.ServerLogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .error: return .red
        }
    }
}
