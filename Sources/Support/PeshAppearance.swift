import SwiftUI
import AppKit

struct PeshBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(red: scheme == .dark ? 8/255 : 246/255,
                  green: scheme == .dark ? 7/255 : 242/255,
                  blue: scheme == .dark ? 13/255 : 249/255)
            RadialGradient(colors: [Theme.accent.opacity(scheme == .dark ? 0.10 : 0.07), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 430)
            RadialGradient(colors: [AppearanceSettings.shared.palette.secondary.color.opacity(0.04), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 330)
        }.ignoresSafeArea()
    }
}

struct PeshAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(PeshBackdrop())
            .tint(Theme.accent)
            // AppKit owns window appearance. A SwiftUI preferredColorScheme
            // override can keep a hosting view light after returning to System.
            .onAppear { WindowManager.shared.updateAppearance() }
            .onChange(of: AppearanceSettings.shared.mode) { _, _ in WindowManager.shared.updateAppearance() }
    }
}

struct PeshMark: View {
    var size: CGFloat = 52
    private static let artwork: NSImage = {
        guard let url = Bundle.main.url(forResource: "PeshMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSApplication.shared.applicationIconImage }
        return image
    }()

    var body: some View {
        Image(nsImage: Self.artwork)
            .renderingMode(.original)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Pesh")
    }
}

struct PeshHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                PeshMark(size: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text("pFlow").peshText(32, .bold, design: .rounded).tracking(-1)
                    Text("BY PESH").peshText(10, .medium, design: .monospaced)
                        .tracking(3).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform").peshText(24, .light).foregroundStyle(Theme.gradient)
            }
            Capsule().fill(Theme.gradient).frame(height: 2)
        }
        .padding(.vertical, 4)
    }
}
