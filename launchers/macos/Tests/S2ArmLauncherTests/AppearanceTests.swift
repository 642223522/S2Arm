import XCTest
import AppKit
import SwiftUI
@testable import S2ArmLauncher

@MainActor final class AppearanceTests: XCTestCase {
    func testPlatformSurfacesAndButtonsRenderOnSupportedSystem() throws {
        let content = PlatformGlassContainer(spacing:12) {
            VStack {
                Button("Regular") {}.platformButtonStyle()
                Button("Primary") {}.platformButtonStyle(prominent:true)
                Button("Disabled") {}.platformButtonStyle().disabled(true)
                Text("Surface").padding().glassSurface()
            }.padding()
        }.frame(width:320,height:240)
        let renderer = ImageRenderer(content:content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width,320)
        XCTAssertEqual(image.height,240)
    }

    func testInAppIconCornersAreTransparentAtSidebarAndEmptyStateSizes() throws {
        let source = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Branding/AppIcon-1024.png")
        let image = try XCTUnwrap(NSImage(contentsOf:source))
        for size in [32.0,48.0,104.0] {
            let renderer = ImageRenderer(content:BrandIcon(image:image,size:size))
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage:try XCTUnwrap(renderer.cgImage))
            let last = bitmap.pixelsWide - 1
            for (x,y) in [(0,0),(last,0),(0,last),(last,last)] {
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:x,y:y)).alphaComponent,0.01)
            }
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:last/2,y:last/2)).alphaComponent,0.99)
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x:last/2,y:0)).alphaComponent,0.95)
        }
    }

    func testSwitchingPersistsAndOnlyOverridesThisApplication() throws {
        let application=NSApplication.shared
        let previous=application.appearance
        let oldLanguage=Localization.preference
        let systemPreference=UserDefaults.standard.string(forKey:"AppleInterfaceStyle")
        defer { application.appearance=previous;Localization.preference=oldLanguage }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-appearance-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        XCTAssertEqual(store.appearance,.system)
        store.appearance = .dark
        XCTAssertEqual(application.appearance?.name,.darkAqua)
        let restarted=Store(privateRoot:root)
        XCTAssertEqual(restarted.appearance,.dark)
        XCTAssertEqual(application.appearance?.name,.darkAqua)
        restarted.appearance = .light
        XCTAssertEqual(application.appearance?.name,.aqua)
        restarted.appearance = .system
        XCTAssertNil(application.appearance)
        XCTAssertEqual(UserDefaults.standard.string(forKey:"AppleInterfaceStyle"),systemPreference)
        let saved=try JSONDecoder().decode(Preferences.self,from:Data(contentsOf:root.appendingPathComponent("preferences.json")))
        XCTAssertEqual(saved.appearance,"system")
    }
    func testLegacyPreferencesAndUnknownAppearanceUseSystem() throws {
        let previous=NSApp?.appearance;let oldLanguage=Localization.preference
        defer {NSApp?.appearance=previous;Localization.preference=oldLanguage}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-old-appearance-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.preferences.appearance="unknown-future-option"
        XCTAssertEqual(store.appearance,.system)
        store.applyAppearance();XCTAssertNil(NSApp?.appearance)
        let legacy=try JSONDecoder().decode(Preferences.self,from:Data(#"{"library":"","libraryId":"","developerDir":"","onboardingComplete":true}"#.utf8))
        XCTAssertNil(legacy.appearance)
    }
}
