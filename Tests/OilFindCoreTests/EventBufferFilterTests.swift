import XCTest
@testable import OilFindCore

/// 扫描期间的事件缓冲只丢 apply 必然拒收的路径；排除目录的高频变动不能再挤爆缓冲触发整盘重建。
final class EventBufferFilterTests: XCTestCase {
    func testExcludedPathsAreDroppedBeforeBuffering() {
        let config = IndexConfig.standard()
        let home = NSHomeDirectory()
        for path in [home + "/Library/Caches/com.example/blob",
                     "/private/var/folders/xx/T/etilqs_1",
                     "/System/Volumes/Data/private/tmp/x",
                     home + "/File/git/repo/.git/objects/ab/cdef",
                     home + "/File/git/repo/.build/debug/x.o",
                     home + "/File/git/site/node_modules/react/index.js"] {
            XCTAssertFalse(IndexUpdater.mayAffectIndex(path, config: config), path)
        }
    }
    func testIndexablePathsSurviveFiltering() {
        let config = IndexConfig.standard()
        let home = NSHomeDirectory()
        for path in [home + "/File/git/repo/README.md",
                     "/System/Volumes/Data" + home + "/Documents/report.pdf",
                     home + "/Documents/",
                     // 末段是依赖目录名时只在「目录」解释下被排除；删除事件拿不到类型，必须保留。
                     home + "/File/git/site/node_modules",
                     "/Applications/Example.app"] {
            XCTAssertTrue(IndexUpdater.mayAffectIndex(path, config: config), path)
        }
    }
    func testFilterHonorsIndexingOptions() {
        let library = NSHomeDirectory() + "/Library/Caches/x"
        XCTAssertTrue(IndexUpdater.mayAffectIndex(library, config: IndexConfig(indexUserLibrary: true)))
        XCTAssertFalse(IndexUpdater.mayAffectIndex("/elsewhere/file", config: IndexConfig(rootPath: "/Volumes/T7")))
        XCTAssertTrue(IndexUpdater.mayAffectIndex("/Volumes/T7/file", config: IndexConfig(rootPath: "/Volumes/T7")))
    }
}
