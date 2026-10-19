import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "1.0"
    }

    var body: some View {
        VStack(spacing: Theme.s4) {
            PeshMark(size: 88)

            VStack(spacing: Theme.s1) {
                Text("pFlow")
                    .font(.system(size: 20, weight: .bold))
                Text("By Pesh · On-device dictation for macOS")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Text("pFlow transcribes your speech entirely on your Mac using Apple Speech or optional local Whisper. No audio ever leaves your machine, and there is no account, API key, or subscription.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.s2)

            Text("Cleanup and templates stay on this Mac by default. Optional Apple Private Cloud Compute sends text and formatting instructions to Apple only when selected.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().overlay(Theme.hairline)

            VStack(spacing: Theme.s2) {
                Link("View source on GitHub", destination: URL(string: "https://github.com/PESHian/yap")!)
                    .font(.system(size: 12, weight: .medium))
                Text("Released under the MIT License.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Based on Yap by")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Link("Frigade", destination: URL(string: "https://frigade.com")!)
                        .font(.system(size: 11, weight: .medium))
                }
                Text("© 2026 Frigade, Inc.")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(Theme.s6)
        .frame(width: 360, height: 440)
    }
}
