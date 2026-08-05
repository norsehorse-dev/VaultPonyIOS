import SwiftUI

/// P6: the root view for an unlocked vault session.
///
/// Presents Browser (content) and Viewer (detail) as a NavigationSplitView.
/// On a regular-width iPad this shows both columns side by side; on
/// compact width (iPhone) SwiftUI automatically collapses it to a single
/// column that pushes/reveals exactly like the old single-stack UX did.
///
/// Folder drill-down lives in its own inner NavigationStack, scoped to the
/// content column, so navigating into subfolders never disturbs which
/// file is selected in the detail column -- and vice versa, picking a
/// different file never resets the folder stack.
struct VaultSessionView: View {
    @State private var folderPath = NavigationPath()
    @State private var selectedFile: FileTarget?

    var body: some View {
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
