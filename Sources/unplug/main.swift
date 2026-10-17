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
        // Clip to the safe area so a scrolled list stops at the titlebar instead
        // of running under the close button.
        AppList(monitor: monitor)
            .clipped()
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
// An empty toolbar only to grow the titlebar band to 38pt, tall enough to hold
// the close button at an even margin.
window.toolbar = NSToolbar()
window.toolbarStyle = .unifiedCompact
window.standardWindowButton(.miniaturizeButton)?.isHidden = true
window.standardWindowButton(.zoomButton)?.isHidden = true
window.isOpaque = false
window.backgroundColor = .clear
// NSHostingController, not a bare NSHostingView as the contentView: the view
// form resolves its own size against the window that is sizing itself from it,
// and inside a real app bundle that loop aborts in AttributeGraph.
window.contentViewController = NSHostingController(rootView: ContentView())
window.setContentSize(NSSize(width: 360, height: 400))
// Open on the built-in display when one is connected, else on the main screen.
let screen = NSScreen.screens.first {
    let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    return id.map { CGDisplayIsBuiltin($0) != 0 } ?? false
} ?? NSScreen.main
if let area = screen?.visibleFrame {
    window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                  y: area.midY - window.frame.height / 2))
}
window.makeKeyAndOrderFront(nil)
// shortcut: 25pt is the .sidebar row inset plus half the 18pt icon, measured on
// macOS 27; derive it from the list's layout if a release moves the inset.
// The close button is centred 25pt in from the left and from the top, so it
// lines up with the icons and its two margins match. AppKit re-tiles the
// titlebar buttons on its own layout passes, so it is pinned back whenever its
// frame moves.
if let close = window.standardWindowButton(.closeButton) {
    let center: CGFloat = 25
    let pin = {
        guard let bar = close.superview else { return }
        let top = bar.isFlipped ? center : bar.bounds.height - center
        let origin = NSPoint(x: center - close.frame.width / 2, y: top - close.frame.height / 2)
        if close.frame.origin != origin { close.setFrameOrigin(origin) }
    }
    close.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: close, queue: .main
    ) { _ in pin() }
    pin()
}
app.run()
