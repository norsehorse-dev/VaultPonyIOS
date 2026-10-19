import SwiftUI

/// File sizes as the rest of the app shows them.
enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// "Volume Info" sheet (2.0.0, issue #3): what is open and how full it is.
struct VolumeInfoView: View {
    @Environment(SessionRegistry.self) private var sessionRegistry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let facts = sessionRegistry.facts {
                    if facts.hidden {
                        Section {
                            Label("Hidden volume", systemImage: "eye.slash")
                        }
                    } else if facts.outerProtected {
                        Section {
                            Label("Hidden area protected", systemImage: "lock.shield")
                        }
                    }
                    Section {
                        LabeledContent("Encryption", value: facts.scheme)
                        LabeledContent("Hash", value: facts.prf)
                        LabeledContent("Filesystem", value: facts.filesystem)
                        if let space = sessionRegistry.space {
                            LabeledContent("Size", value: ByteFormat.string(space.totalBytes))
                            LabeledContent("Free", value: ByteFormat.string(space.freeBytes))
                        }
                        LabeledContent("Access") {
                            if facts.writable {
                                Text("Read and write")
                            } else {
                                Text("Read-only")
                            }
                        }
                    } footer: {
                        if facts.maxFileBytes != nil {
                            Text("FAT holds files up to 4 GB each.")
                        }
                    }
                }
            }
            .navigationTitle("Volume Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await sessionRegistry.refreshFacts()
                await sessionRegistry.refreshSpace()
            }
        }
    }
}
