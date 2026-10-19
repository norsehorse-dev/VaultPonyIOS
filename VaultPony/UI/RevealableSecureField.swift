import SwiftUI
import UIKit

/// A password field with an eye button that shows what's been typed.
/// Starts masked and goes back to masked when the screen is left (the
/// reveal state is view-local). The revealed field keeps the secure
/// field's input settings: ASCII keyboard, no autocorrection, no
/// capitalization, so revealing never feeds the password to the
/// keyboard's learning.
///
/// `contentType` tells password managers what the field is: `.password`
/// for an existing password (unlock, current password), `.newPassword` on
/// create and change-password screens.
struct RevealableSecureField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var accessibilityIdentifier: String? = nil
    var contentType: UITextContentType = .password

    @State private var revealed = false

    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField(title, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(contentType)
                } else {
                    SecureField(title, text: $text)
                        .textContentType(contentType)
                }
            }
            .keyboardType(.asciiCapable)
            .accessibilityIdentifier(accessibilityIdentifier ?? "")

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? Text("Hide password") : Text("Show password"))
        }
    }
}
