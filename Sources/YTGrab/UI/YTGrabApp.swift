import AppKit
import SwiftUI

@main
struct YTGrabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 780, height: 560)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.terminateCurrent()
        BrowseManager.terminateCurrent()
    }
}
