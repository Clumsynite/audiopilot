import AppKit
import SwiftUI

/// An app's Finder icon by bundle ID, or a generic app symbol.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 18

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size)
        }
    }
}
