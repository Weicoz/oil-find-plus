import AppKit
import XCTest
@testable import OilFindApp

final class AITopicResourceTests: XCTestCase {
    func testEveryProviderHasABundledIcon() {
        // dsh 没有可随包分发的图标，运行时取已安装应用的图标，缺失时回落到系统符号。
        for provider in AITopicProvider.allCases where provider != .dsh {
            XCTAssertNotNil(AITopicIcons.bundledImage(provider), provider.rawValue)
        }
    }

    func testInstalledResourcesResolveWithoutTheBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Oil Find.app/Contents/Resources")
        let icons = resources.appendingPathComponent("OilFind_OilFindApp.bundle/Resources/TopicIcons")
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let source = try XCTUnwrap(AITopicIcons.bundledImage(.codex)?.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: source))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: icons.appendingPathComponent("codex.png"))
        XCTAssertNotNil(AITopicIcons.bundledImage(.codex, directories: [resources]))
        XCTAssertNil(AITopicIcons.bundledImage(.claude, directories: [resources]))
    }

    func testMissingResourcesAllowTheFallbackIcon() {
        XCTAssertNil(AITopicIcons.bundledImage(.codex, directories: []))
    }
}
