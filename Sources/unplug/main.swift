import AppKit
import SwiftUI

if CommandLine.arguments.contains("--self-check") {
    exit(selfCheck())
}

// The app runs as the ordinary user. Only pfctl is privileged, through the
// sudoers rule run.sh installs — see Blocker.

// Behind-window blur, the Finder sidebar look. SwiftUI's own .ultraThinMaterial
// blurs only what is inside the window, so this stays an AppKit view.
struct Vibrancy: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

struct AppList: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        // No selection binding: writing one back during the same update that
        // refreshes `apps` aborts with an AttributeGraph cycle, and nothing here
        // needs a selected row.
        List {
            ForEach(monitor.apps) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { !monitor.isBlocked(app) },
                        set: { monitor.setBlocked(app, !$0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(monitor.isBlocked(app) ? "network off" : "network on")
                }
                .padding(.vertical, 3)  // 28pt sidebar row pitch, +20%
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

struct ContentView: View {
    @StateObject private var monitor = Monitor()

    var body: some View {
        AppList(monitor: monitor)
            .background(Vibrancy().ignoresSafeArea())
            .task { monitor.start() }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
    // no Quit button any more, so closing the window is what releases pf
    func applicationWillTerminate(_: Notification) {
        MainActor.assumeIsolated { Monitor.shared?.flush() }
    }
}

let delegate = Delegate()
let app = NSApplication.shared
app.delegate = delegate
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
    styleMask: [.titled, .closable, .fullSizeContentView],
    backing: .buffered, defer: false)
window.title = "Unplug"
// Titlebar keeps only the traffic lights; the list runs the full height behind
// it, and the window is clear so the vibrancy view is what shows.
window.titleVisibility = .hidden
window.titlebarAppearsTransparent = true
window.isMovableByWindowBackground = true
window.standardWindowButton(.miniaturizeButton)?.isHidden = true
window.standardWindowButton(.zoomButton)?.isHidden = true
window.isOpaque = false
window.backgroundColor = .clear
// NSHostingController, not a bare NSHostingView as the contentView: the view
// form resolves its own size against the window that is sizing itself from it,
// and inside a real app bundle that loop aborts in AttributeGraph.
window.contentViewController = NSHostingController(rootView: ContentView())
window.setContentSize(NSSize(width: 360, height: 400))
window.center()
window.makeKeyAndOrderFront(nil)
app.run()
