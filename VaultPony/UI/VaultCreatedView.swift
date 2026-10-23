import SwiftUI

struct VaultCreatedView: View {
    let summary: CreatedVaultSummary
    @Binding var path: NavigationPath

    /// Set only when this view is reached from the onboarding carousel's
    /// Create-vault sheet (see OnboardingView.swift). When present, "Open
    /// Vault" is hidden (there's no vault-detail destination registered in
    /// that self-contained sheet stack) and the closing button reads
    /// "Continue" and calls back into onboarding instead of resetting
    /// `path`, mirroring Android's `continueSetup` flow.
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: summary.isHidden ? "lock.shield.fill" : "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Vault Created")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                DetailRow(label: "Name", value: summary.vault.displayName)
                DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(summary.sizeBytes), countStyle: .file))
                DetailRow(label: "Encryption", value: "\(Vault.schemeLabel(summary.scheme)) / \(summary.prf)")
                DetailRow(label: "Filesystem", value: summary.filesystem)
                if summary.isHidden, let hiddenSize = summary.hiddenSizeBytes {
                    DetailRow(label: "Hidden Volume", value: ByteCountFormatter.string(fromByteCount: Int64(hiddenSize), countStyle: .file))
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

            if summary.isHidden {
                Text("Remember both passwords — the outer password opens the decoy volume, the hidden password opens the real one. Neither can be recovered if it's lost.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()

            if onDone == nil {
                NavigationLink(value: summary.vault) {
                    Text("Open Vault")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button(onDone == nil ? "Done" : "Continue") {
                if let onDone {
                    onDone()
                } else {
                    path = NavigationPath()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
