import AppKit
import SwiftUI

/// The Osprey menu-bar companion.
///
/// The item shows a bird, and a count when proposals are waiting for review.
/// Opening it reveals the store summary and the pending proposals. Nothing
/// happens until a person clicks a button.
@main
struct OspreyBarApp: App {
    @NSApplicationDelegateAdaptor(OspreyBarDelegate.self) private var delegate
    @StateObject private var model = OspreyBarModel()

    var body: some Scene {
        MenuBarExtra {
            OspreyMenuView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.statusSymbol)
                if model.pendingCount > 0 {
                    Text("\(model.pendingCount)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app out of the Dock so only the menu-bar item shows.
final class OspreyBarDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
