import SwiftUI

/// The one setup step for live words in every app: macOS lets only the
/// person add pFlow Dictation as an input source, once. The row shows the
/// plain steps and one button; it turns done by itself once the source is on.
struct InputMethodSetupRow: View {
    @State private var enabled = InputMethodInstall.enabled
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    static let title = "Live words in every app"
    static let steps = "In Keyboard settings: Text Input, Edit…, the + button, English, pFlow Dictation, Add. Once is enough."
    static let doneDetail = "pFlow Dictation is on. Words show in your app as you talk."

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 36, height: 36)
                Image(systemName: "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title).font(.system(size: 13, weight: .semibold))
                Text(enabled ? Self.doneDetail : Self.steps)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.s2)
            if enabled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.success)
                    .accessibilityLabel("Done")
            } else {
                Button("Open Keyboard Settings") { NSWorkspace.shared.open(InputMethodInstall.keyboardSettings) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(Theme.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        // Checked only while the row is on screen.
        .onReceive(timer) { _ in
            let now = InputMethodInstall.enabled
            if now != enabled { enabled = now }
        }
        .onAppear { enabled = InputMethodInstall.enabled }
    }
}
