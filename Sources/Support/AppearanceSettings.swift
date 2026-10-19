import AppKit
import SwiftUI
import Observation

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum ColorTheme: String, CaseIterable, Identifiable {
    case pesh, aurora, solar, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum WaveformStyle: String, CaseIterable, Identifiable {
    case wave, lines
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Store portable RGB values, never archived platform color objects.
struct ThemeColor: Equatable {
    let hex: String

    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        self.hex = value.uppercased()
    }

    init(color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> Int { value.isFinite ? Int((min(1, max(0, value)) * 255).rounded()) : 0 }
        self.hex = String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    var color: Color {
        let number = UInt32(hex, radix: 16)!
        return Color(.sRGB, red: Double((number >> 16) & 255) / 255,
                     green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255, opacity: 1)
    }
}

struct ThemePalette: Equatable {
    let primary: ThemeColor
    let secondary: ThemeColor
    var spectrum: [ThemeColor] = []
    var locations: [Double] = []

    // PESH/src/styles/global.css --iris. Keep the owner's weighted green finish.
    static let pesh = ThemePalette(primary: ThemeColor(hex: "FF9DC4")!, secondary: ThemeColor(hex: "3DFF85")!,
        spectrum: ["FF9DC4", "E04F8C", "7C4DFF", "52F0DD", "9DFF5C", "3DFF85"].map { ThemeColor(hex: $0)! },
        locations: [0, 0.14, 0.31, 0.50, 0.72, 1])
    static let aurora = ThemePalette(primary: ThemeColor(hex: "4EE5B3")!, secondary: ThemeColor(hex: "65BFFF")!)
    static let solar = ThemePalette(primary: ThemeColor(hex: "FFBB66")!, secondary: ThemeColor(hex: "FF7188")!)
    var gradient: LinearGradient {
        let colors = spectrum.isEmpty ? [primary, secondary] : spectrum
        let positions = locations.isEmpty ? [0.0, 1.0] : locations
        return LinearGradient(stops: zip(colors, positions).map { .init(color: $0.0.color, location: $0.1) },
                              startPoint: UnitPoint(x: 0, y: 0.375), endPoint: UnitPoint(x: 1, y: 0.625))
    }
}

@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()
    private let defaults: UserDefaults
    var mode: AppearanceMode { didSet { defaults.set(mode.rawValue, forKey: "pflow.appearance.mode") } }
    var theme: ColorTheme { didSet { defaults.set(theme.rawValue, forKey: "pflow.appearance.theme") } }
    var waveformStyle: WaveformStyle { didSet { defaults.set(waveformStyle.rawValue, forKey: "pflow.appearance.waveform") } }
    var customPrimary: ThemeColor { didSet { defaults.set(customPrimary.hex, forKey: "pflow.appearance.primary") } }
    var customSecondary: ThemeColor { didSet { defaults.set(customSecondary.hex, forKey: "pflow.appearance.secondary") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppearanceMode(rawValue: defaults.string(forKey: "pflow.appearance.mode") ?? "") ?? .dark
        theme = ColorTheme(rawValue: defaults.string(forKey: "pflow.appearance.theme") ?? "") ?? .pesh
        waveformStyle = WaveformStyle(rawValue: defaults.string(forKey: "pflow.appearance.waveform") ?? "") ?? .wave
        customPrimary = ThemeColor(hex: defaults.string(forKey: "pflow.appearance.primary") ?? "") ?? ThemePalette.pesh.primary
        customSecondary = ThemeColor(hex: defaults.string(forKey: "pflow.appearance.secondary") ?? "") ?? ThemePalette.pesh.secondary
    }

    var palette: ThemePalette {
        switch theme {
        case .pesh: .pesh
        case .aurora: .aurora
        case .solar: .solar
        case .custom: ThemePalette(primary: customPrimary, secondary: customSecondary)
        }
    }
}
