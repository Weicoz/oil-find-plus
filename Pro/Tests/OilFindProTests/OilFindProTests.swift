import XCTest
@testable import OilFindPro

final class OilFindProTests: XCTestCase {
    func testExtensionInitialization() {
        let ext = OilFindProExtension()
        XCTAssertNotNil(ext.supplementarySearchProvider)
    }
}
