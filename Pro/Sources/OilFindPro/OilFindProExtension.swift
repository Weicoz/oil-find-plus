import Foundation
import AppKit
import SwiftUI
import Combine
import OilFindCore
import OilFindApp


private struct ProSettingsView: View {
    @State private var ocrEnabled: Bool = ContentManager.shared.isOcrEnabled
    @State private var dbSize: String = ContentManager.shared.databaseSizeString()
    @State private var isClearing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Oil Find Pro (内容搜索扩展)")
                .font(.headline)

            Toggle("启用文档与图片内容搜索 (OCR)", isOn: $ocrEnabled)
                .onChange(of: ocrEnabled) { _, newValue in
                    ContentManager.shared.setOcrEnabled(newValue)
                }

            Text("离线识别 Desktop、Documents、Downloads、Pictures 等个人目录中的图片与文档文字；开发依赖及系统目录自动排除。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("索引缓存占用：\(dbSize)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(isClearing ? "正在清理..." : "清空缓存瘦身") {
                    isClearing = true
                    ContentManager.shared.clearDatabase {
                        dbSize = ContentManager.shared.databaseSizeString()
                        isClearing = false
                    }
                }
                .disabled(isClearing)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            ocrEnabled = ContentManager.shared.isOcrEnabled
            dbSize = ContentManager.shared.databaseSizeString()
        }
    }
}

public final class OilFindProExtension: ApplicationExtension {
    private let provider = ContentSearchProvider()
    public var onSearchSourcesChange: (() -> Void)?
    public var onSettingsMenuItemChange: (() -> Void)?

    public var supplementarySearchProvider: SupplementarySearchProvider? {
        return provider
    }

    private var showSettingsCallback: (() -> Void)?

    public var settingsMenuItem: ApplicationMenuItem? {
        return ApplicationMenuItem(title: "Oil Find Pro", isVisible: true) { [weak self] in
            self?.showSettingsCallback?()
        }
    }

    public init() {}

    public func start(chinese: Bool, showSettings: @escaping () -> Void) {
        self.showSettingsCallback = showSettings
    }

    public func stop() {
        // Stopped
    }

    public func languageDidChange(chinese: Bool) {
        // Handle language change
    }

    public func handle(_ url: URL) {
        // Handle custom URL scheme if any
    }

    public func searchSources() -> [SearchSource] {
        return []
    }

    public func settingsSection(window: @escaping () -> NSWindow?) -> AnyView {
        return AnyView(ProSettingsView())
    }
}
