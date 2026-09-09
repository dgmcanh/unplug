import AppKit
import SwiftUI

if CommandLine.arguments.contains("--self-check") {
    exit(selfCheck())
}

// The app runs as the ordinary user. Only pfctl is privileged, through the
// sudoers rule run.sh installs — see Blocker.

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
            }
        }
        .listStyle(.sidebar)
    }
}

struct ContentView: View {
    @StateObject private var monitor = Monitor()

    var body: some View {
        AppList(monitor: monitor).task { monitor.start() }
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
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 680),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
window.title = "Unplug"
// NSHostingController, not a bare NSHostingView as the contentView: the view
// form resolves its own size against the window that is sizing itself from it,
// and inside a real app bundle that loop aborts in AttributeGraph.
window.contentViewController = NSHostingController(rootView: ContentView())
window.setContentSize(NSSize(width: 360, height: 680))
window.center()
window.makeKeyAndOrderFront(nil)
app.run()
