import SwiftUI

/// P6: the root view for an unlocked vault session.
///
/// Two layouts, chosen by horizontal size class:
///
/// - Regular width (iPad): a NavigationSplitView with Browser (content)
///   and Viewer (detail) side by side. Folder drill-down lives in its own
///   inner NavigationStack scoped to the content column, so navigating
///   into subfolders never disturbs which file is selected in the detail
///   column — and vice versa.
///
/// - Compact width (iPhone, iPad split-screen): plain pushes on the
///   *outer* NavigationStack (HomeView's — VaultSessionView is itself a
///   pushed destination inside it). This branch exists because SwiftUI
///   only supports NavigationSplitView as the root of a navigation
///   hierarchy: a stack can be a split-view column, but a split view
///   pushed inside a stack cannot perform its collapsed-mode column
///   navigation — on iPhone, tapping a file updated `selectedFile` and
///   nothing ever appeared (preferredCompactColumn was ignored too;
///   SnapshotTests' 04Viewer step caught this). On iPad the split view
///   never needs a column push, both columns are just visible, so the
///   regular-width branch works fine as a pushed destination.
///
/// `selectedFile` drives both layouts: the split view renders it in the
/// detail column, the compact branch pushes ViewerView via
/// `navigationDestination(item:)` (swipe-back clears it automatically).
struct VaultSessionView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var folderPath = NavigationPath()
    @State private var selectedFile: FileTarget?

    var body: some View {
        if horizontalSizeClass == .compact {
            BrowserView(path: "/", selectedFile: $selectedFile)
                .navigationDestination(for: String.self) { subPath in
                    BrowserView(path: subPath, selectedFile: $selectedFile)
                }
                .navigationDestination(item: $selectedFile) { file in
                    ViewerView(path: file.path, name: file.name)
                }
        } else {
            NavigationSplitView {
                NavigationStack(path: $folderPath) {
                    BrowserView(path: "/", selectedFile: $selectedFile)
                        .navigationDestination(for: String.self) { subPath in
                            BrowserView(path: subPath, selectedFile: $selectedFile)
                        }
                }
            } detail: {
                if let selectedFile {
                    ViewerView(path: selectedFile.path, name: selectedFile.name)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose a file from the list to preview it here.")
                    )
                }
            }
        }
    }
}
