import Foundation
import XCTest
@testable import RecordToTextCore

final class GCloudAuthServiceTests: XCTestCase {
    func testMissingGCloudExecutableThrows() async {
        let auth = GCloudAuthService(customGCloudPath: "/invalid/path/to/nonexistent_gcloud")
        XCTAssertNil(auth.resolveGCloudURL())

        do {
            _ = try await auth.getAccessToken()
            XCTFail("Should throw gcloudNotFound")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .gcloudNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await auth.getDefaultProjectID()
            XCTFail("Should throw gcloudNotFound")
        } catch let error as GCloudAuthError {
            XCTAssertEqual(error, .gcloudNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
