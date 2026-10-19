import Foundation
import AppKit
import SwiftUI
import Testing
import CryptoKit
@testable import Yap

@MainActor
struct AppearanceSettingsTests {
    @Test func bundledPeshArtworkAndVisibleAppNameAreAvailable() throws {
        let mark = try #require(Bundle.main.url(forResource: "PeshMark", withExtension: "png"))
        let icon = try #require(Bundle.main.url(forResource: "Pesh", withExtension: "icns"))
        #expect(NSImage(contentsOf: mark) != nil)
        #expect(NSImage(contentsOf: icon) != nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "pFlow")
        #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "pFlow")
    }

    @Test func settingsHeaderShowsColoredPigInLightAndDark() throws {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: PeshHeader().frame(width: 420).environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            #expect(bitmap.pixelsWide == 840)
            var coloredPixels = 0
            // The first 62 points contain the pig, above the thin gradient rule.
            // The rule alone cannot satisfy this count if the pig is blank.
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<124 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.5 else { continue }
                    let components = [color.redComponent, color.greenComponent, color.blueComponent]
                    if components.max()! - components.min()! > 0.2 { coloredPixels += 1 }
                }
            }
            #expect(coloredPixels > 600, "Pesh pig is missing from the Settings header")
        }
    }

    @Test func originalSpeakingPigHasTransparentBackground() throws {
        let url = try #require(Bundle.main.url(forResource: "PeshMark", withExtension: "png"))
        let data = try Data(contentsOf: url)
        // Exact PeshSpeaking artwork from the original native pFlow project.
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                == "f02898ca7b79783903329ea265407298e5e16147aeb8a217bef3f4b715b09b87")
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide == 264 && bitmap.pixelsHigh == 240)
        #expect(bitmap.hasAlpha)
        for (x, y) in [(0, 0), (263, 0), (0, 239), (263, 239)] {
            #expect(try #require(bitmap.colorAt(x: x, y: y)).alphaComponent == 0)
        }
        // Draw the shared mark too: its view must not add a black tile.
        let renderer = ImageRenderer(content: PeshMark(size: 62))
        renderer.scale = 2
        let rendered = try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        #expect(try #require(rendered.colorAt(x: 0, y: 0)).alphaComponent == 0)
        #expect(try #require(rendered.colorAt(x: rendered.pixelsWide - 1, y: rendered.pixelsHigh - 1)).alphaComponent == 0)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "pflow.appearance.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func customColorsAndModeSurviveRelaunch() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppearanceSettings(defaults: defaults)
        first.mode = .light
        first.theme = .custom
        first.waveformStyle = .lines
        first.customPrimary = ThemeColor(hex: "#12aB34")!
        first.customSecondary = ThemeColor(hex: "34CDff")!
        let restored = AppearanceSettings(defaults: defaults)
        #expect(restored.mode == .light)
        #expect(restored.theme == .custom)
        #expect(restored.waveformStyle == .lines)
        #expect(restored.palette.primary.hex == "12AB34")
        restored.waveformStyle = .wave
        #expect(AppearanceSettings(defaults: defaults).waveformStyle == .wave)
        #expect(restored.palette.secondary.hex == "34CDFF")
        restored.theme = .aurora
        #expect(restored.palette == .aurora)
        restored.theme = .custom
        #expect(restored.palette.primary.hex == "12AB34")
    }

    @Test func invalidSavedPreferencesRecoverWithoutLosingHistorySettings() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("invalid", forKey: "pflow.appearance.theme")
        defaults.set("invalid", forKey: "pflow.appearance.mode")
        defaults.set("invalid", forKey: "pflow.appearance.waveform")
        defaults.set("ZZ1234", forKey: "pflow.appearance.primary")
        defaults.set("#12345678", forKey: "pflow.appearance.secondary")
        defaults.set(false, forKey: "soundsEnabled")
        defaults.set(123.5, forKey: "pflow.hud.x")
        let settings = AppearanceSettings(defaults: defaults)
        #expect(settings.mode == .dark && settings.theme == .pesh)
        #expect(settings.waveformStyle == .wave)
        #expect(settings.palette == .pesh)
        #expect(settings.customPrimary == ThemePalette.pesh.primary)
        #expect(settings.customSecondary == ThemePalette.pesh.secondary)
        #expect(!defaults.bool(forKey: "soundsEnabled"))
        #expect(defaults.double(forKey: "pflow.hud.x") == 123.5)
    }

    @Test func existingUsersKeepTheirCurrentWaveform() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppearanceSettings(defaults: defaults).waveformStyle == .wave)
        #expect(defaults.object(forKey: "pflow.appearance.waveform") == nil)
    }
}
