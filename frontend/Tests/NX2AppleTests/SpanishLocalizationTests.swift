import XCTest
@testable import NX2Apple
@testable import NXCore
@testable import NXLauncher

/// The Spanish overlay reads as natural Spanish: proper nouns and brands stay intact (`Switch`, `Switch 2`, `MetalFX`, `IPA`,
/// `Homebrew`, `Python`, `Shell`), nothing is left in English except the listed names/units, and literal machine-translation
/// slips stay out. Completeness and placeholders for every language are in NXCoreTests/LocalizationRulesTests.swift.
final class SpanishLocalizationTests: IsolatedDefaultsTestCase {
    /// Keys whose Spanish text intentionally matches English: brands, tool names, units, button letters.
    static let sameAsEnglish: Set<String> = [
        "build.ios", "build.tvos", "console.batteryPercent", "console.fps30", "console.fps60",
        "console.platform.iphone", "console.platform.mac", "controls.fn.A", "controls.fn.B", "controls.fn.L",
        "controls.fn.Minus", "controls.fn.Plus", "controls.fn.R", "controls.fn.X", "controls.fn.Y",
        "controls.fn.ZL", "controls.fn.ZR", "controls.steam.L4", "controls.steam.L5",
        "controls.steam.R4", "controls.steam.R5", "controls.steam.title", "data.keys",
        "delete.part.ipa", "dep.brew", "dep.dotnet", "dep.glslang", "dep.metal", "dep.python.hint",
        "dep.spirv", "dep.spirv.win", "dep.tool.glslangValidator", "dep.tool.spirv-cross",
        "dep.tool.xcodegen", "dep.tool.zstd", "dep.xcodegen", "dep.zstd", "dep.zstd.win",
        "engine.channel.experimental", "engine.detail", "ios.host.ok", "ios.host.shellName",
        "launch.mods", "launch.opt.DM_FPS_TARGET.120", "launch.opt.DM_FPS_TARGET.30",
        "launch.opt.DM_FPS_TARGET.60", "launch.opt.DM_PRESENT_UPSCALE.metalfx",
        "launch.opt.DM_SCREEN_ASPECT.0", "launch.opt.DM_UPSCALER.metalfx", "library.ok",
        "msg.ipaAt", "onboarding.background.dotnet", "onboarding.background.python",
        "onboarding.demo.mario", "onboarding.platform.iphone", "onboarding.platform.mac",
        "onboarding.setup.metal", "saves.toDevice", "saves.toMac", "switch2.badge",
    ]

    func testNothingIsLeftInEnglishButTheListedNames() {
        let english = L10n.table.compactMap { key, row in L10n.es[key] == row.en ? key : nil }
        XCTAssertEqual(Set(english), Self.sameAsEnglish)
    }

    func testSpanishIsSelectedAndPreservesConsoleAndToolNames() {
        XCTAssertEqual(Lang.find("es"), Lang("es"))
        XCTAssertEqual(Lang("es").name, "Español", "a language's name is in that language")
        XCTAssertEqual(L10n.string("switch2.badge", Lang("es")), "Switch 2")
        XCTAssertEqual(L10n.string("launch.opt.DM_SCREEN_ASPECT.0", Lang("es")), "16:9 (Switch)")
        XCTAssertEqual(L10n.string("launch.set.DM_SHOW_FPS", Lang("es")), "HUD de estadísticas")
        XCTAssertEqual(L10n.string("ios.host.shellName", Lang("es")), "Shell")
        XCTAssertEqual(L10n.string("homeQuit.quit", Lang("es")), "Salir")
        XCTAssertEqual(L10n.string("ios.host.quitButton", Lang("es")), "Salir")
        XCTAssertEqual(L10n.string("dep.brew", Lang("es")), "Homebrew")
        XCTAssertTrue(L10n.string("cheats.pickMessage", Lang("es")).contains("atmosphere/contents/<title ID>/cheats"))
    }
}
