import XCTest
@testable import Intreccio

@MainActor
final class T3CodeApplicationServiceTests: XCTestCase {
    func testSocketPathMatchesT3ControlAddressDerivation() {
        let path = T3CodeApplicationService.socketPath(
            stateDirectory: "/Users/alice/.t3/userdata",
            temporaryDirectory: "/var/folders/tmp/",
            userID: 501
        )

        XCTAssertEqual(
            path,
            "/var/folders/tmp/t3code-501/22e363ab54323d33fbf88771.sock"
        )
    }

    func testValidatesSuccessfulActivationResponse() throws {
        let response = try T3CodeApplicationService.validateResponse(
            Data(
                """
                {"version":1,"requestId":"request-1","ok":true,"projectId":"project-1","threadId":"thread-1"}
                """.utf8
            ),
            requestID: "request-1"
        )

        XCTAssertEqual(
            response,
            T3CodeWorkspaceActivation(projectID: "project-1", threadID: "thread-1")
        )
    }

    func testSurfacesProjectCreationFailure() {
        XCTAssertThrowsError(
            try T3CodeApplicationService.validateResponse(
                Data(
                    """
                    {"version":1,"requestId":"request-1","ok":false,"code":"project-create-failed","message":"Project path is not available."}
                    """.utf8
                ),
                requestID: "request-1"
            )
        ) { error in
            guard case .projectCreationFailed("Project path is not available.") = error as? T3CodeApplicationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSurfacesThreadOpenFailure() {
        XCTAssertThrowsError(
            try T3CodeApplicationService.validateResponse(
                Data(
                    """
                    {"version":1,"requestId":"request-1","ok":false,"code":"thread-open-failed","message":"Thread unavailable."}
                    """.utf8
                ),
                requestID: "request-1"
            )
        ) { error in
            guard case .threadOpenFailed("Thread unavailable.") = error as? T3CodeApplicationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectsSuccessWithoutBothIdentifiers() {
        XCTAssertThrowsError(
            try T3CodeApplicationService.validateResponse(
                Data(
                    """
                    {"version":1,"requestId":"request-1","ok":true,"projectId":"project-1"}
                    """.utf8
                ),
                requestID: "request-1"
            )
        ) { error in
            guard case .invalidSocketResponse = error as? T3CodeApplicationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
    func testChannelMenuTitles() {
        XCTAssertEqual(T3CodeApplicationChannel.latest.menuTitle, "T3 Code")
        XCTAssertEqual(T3CodeApplicationChannel.nightly.menuTitle, "T3 Code (Nightly)")
        XCTAssertEqual(T3CodeApplicationChannel.localBuild.menuTitle, "T3 Code (Local Build)")
    }

    func testVersionOrderingUsesNumericComponents() {
        XCTAssertTrue(T3CodeApplicationService.versionIsNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(T3CodeApplicationService.versionIsNewer("1.9.0", than: "1.10.0"))
    }


    func testApplicationRevalidationResolvesReplacementAtSameURL() {
        let url = URL(fileURLWithPath: "/Applications/T3 Code.app")
        let selected = T3CodeInstalledApplication(url: url, channel: .latest, version: "1.9.0")
        let replacement = T3CodeInstalledApplication(url: url, channel: .latest, version: "1.10.0")

        XCTAssertEqual(
            T3CodeApplicationService.currentApplication(matching: selected, among: [replacement]),
            replacement
        )
    }

    func testApplicationRevalidationRejectsRemovedOrChangedChannel() {
        let url = URL(fileURLWithPath: "/Applications/T3 Code.app")
        let selected = T3CodeInstalledApplication(url: url, channel: .latest, version: "1.9.0")
        let nightly = T3CodeInstalledApplication(url: url, channel: .nightly, version: "1.10.0")

        XCTAssertNil(T3CodeApplicationService.currentApplication(matching: selected, among: []))
        XCTAssertNil(T3CodeApplicationService.currentApplication(matching: selected, among: [nightly]))
    }
}