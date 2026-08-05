import SwiftUI
import UIKit
import PDFKit

struct ViewerView: View {
    let path: String
    let name: String

    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(AppPrefs.self) private var appPrefs
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var textContent: String?
    @State private var image: UIImage?
    @State private var pdfDocument: PDFDocument?

    /// P1 viewer cap: text/image/PDF only, up to this size. Larger or
    /// unrecognized files wait for export (P2) rather than loading
    /// unbounded data into memory (PLAN.md section 9). Content is always
    /// streamed in via read_at chunks below and held only in memory —
    /// never written to disk — which is what makes the viewer no-trace
    /// safe by construction (P5).
    private static let maxInlineBytes: UInt64 = 32 << 20

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn't Open File",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if let textContent {
                ScrollView {
                    // No-trace mode disables text selection: the system
                    // copy/share menu it enables is a pasteboard write we
                    // don't control or expire. .enabled/.disabled are
                    // different concrete TextSelectability types, so this
                    // has to be a real if/else (a ViewBuilder branch) --
                    // a ternary can't unify them the way this can.
                    Group {
                        if appPrefs.noTraceMode {
                            Text(textContent).textSelection(.disabled)
                        } else {
                            Text(textContent).textSelection(.enabled)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else if let pdfDocument {
                PDFKitView(document: pdfDocument)
            } else {
                ContentUnavailableView(
                    "Preview Not Available",
                    systemImage: "doc.questionmark",
                    description: Text("VaultPony doesn't have a built-in preview for this file type yet.")
                )
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAppear { sessionRegistry.markActivity() }
    }

    private func load() async {
        guard let session = sessionRegistry.session else {
            errorMessage = "Vault is locked."
            isLoading = false
            return
        }
        do {
            let stat = try await Vault.stat(session, path: path)
            guard stat.size <= Self.maxInlineBytes else {
                errorMessage = "This file is too large to preview yet (\(ByteCountFormatter.string(fromByteCount: Int64(stat.size), countStyle: .file)))."
                isLoading = false
                return
            }

            var data = Data()
            data.reserveCapacity(Int(stat.size))
            var offset: UInt64 = 0
            let chunkSize: UInt32 = 4 << 20
            while offset < stat.size {
                let chunk = try await Vault.readAt(session, path: path, offset: offset, len: chunkSize)
                if chunk.isEmpty { break }
                data.append(chunk)
                offset += UInt64(chunk.count)
            }

            classify(data)
        } catch let error as VaultError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func classify(_ data: Data) {
        let ext = (name as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "heic", "webp"]
        let textExts: Set<String> = ["txt", "md", "log", "json", "xml", "csv", "swift", "kt", "rs", "yml", "yaml", "toml", "conf", "ini"]

        if ext == "pdf", let doc = PDFDocument(data: data) {
            pdfDocument = doc
            return
        }
        if imageExts.contains(ext), let decoded = UIImage(data: data) {
            image = decoded
            return
        }
        if textExts.contains(ext) || looksLikeText(data) {
            textContent = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return
        }
    }

    private func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(4096)
        return !sample.contains(0)
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = document
    }
}
