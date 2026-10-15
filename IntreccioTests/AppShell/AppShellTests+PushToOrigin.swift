import AppKit
@testable import Intreccio
import XCTest

extension AppShellTests {
    func testPushToOriginPolicyRequiresOriginCommitsAndPassingGate() {
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.upstream = "origin/main"
        status.branch.ahead = 2
        status.pushAccess = .allowed

        XCTAssertTrue(PushToOriginPolicy.hasOutgoingOriginCommits(status: status))
        XCTAssertTrue(PushToOriginPolicy.isReady(status: status))

        status.branch.upstream = "fork/main"
        XCTAssertFalse(PushToOriginPolicy.hasOutgoingOriginCommits(status: status))
        status.branch.upstream = "origin/main"
        status.pushAccess = .denied
        XCTAssertFalse(PushToOriginPolicy.isReady(status: status))

        status.pushAccess = .allowed
        status.branch.behind = 1
        XCTAssertFalse(PushToOriginPolicy.isReady(status: status))
    }

    @MainActor
    func testRepositoryDisplayNamesDisambiguateDuplicateBasenames() throws {
        let first = try makePushCandidate(name: "repo", ahead: 1)
        let second = try makePushCandidate(name: "repo", ahead: 1)
        let names = RepoDescriptor.disambiguatedDisplayNames(for: [first.repository, second.repository])

        XCTAssertEqual(
            names[first.repository.id],
            "repo — \(first.repository.canonicalURL.path)"
        )
        XCTAssertEqual(
            names[second.repository.id],
            "repo — \(second.repository.canonicalURL.path)"
        )
        XCTAssertNotEqual(names[first.repository.id], names[second.repository.id])
    }

    @MainActor
    func testPushToOriginPickerUpdatesSelectedRepositoryAndCommitCounts() throws {
        let first = try makePushCandidate(name: "first", ahead: 2)
        let second = try makePushCandidate(name: "second", ahead: 1)
        let blocked = try makePushCandidate(name: "blocked", ahead: 4, pushAccess: .denied)
        let picker = PushToOriginPickerController()
        let pushButton = NSButton(title: "Push Selected (0)", target: nil, action: nil)
        picker.pushButton = pushButton
        picker.setCandidates([first, second, blocked])

        XCTAssertEqual(picker.selectionSummary, "2 selected · 3 commits")
        XCTAssertEqual(pushButton.title, "Push Selected (2)")
        XCTAssertEqual(
            picker.selectedCandidates.map(\.repository.canonicalURL),
            [first.repository.canonicalURL, second.repository.canonicalURL]
        )

        let tableView = try XCTUnwrap(
            allDescendantViews(in: picker.view).compactMap { $0 as? NSTableView }.first
        )
        let checkboxCell = try XCTUnwrap(tableView.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let checkbox = try XCTUnwrap(
            allDescendantViews(in: checkboxCell).compactMap { $0 as? NSButton }.first
        )
        checkbox.performClick(nil)

        XCTAssertEqual(picker.selectionSummary, "1 selected · 2 commits")
        XCTAssertEqual(pushButton.title, "Push Selected (1)")
        XCTAssertEqual(picker.selectedCandidates.map(\.repository.canonicalURL), [first.repository.canonicalURL])
    }

    @MainActor
    private func makePushCandidate(
        name: String,
        ahead: Int,
        pushAccess: PushAccess = .allowed
    ) throws -> PushToOriginCandidate {
        let repositoryID = UUID()
        let url = try makeTestDirectory().appendingPathComponent(name, isDirectory: true)
        let repository = RepoDescriptor(
            id: repositoryID,
            source: .standalone(id: repositoryID),
            url: url,
            canonicalURL: url,
            resourceID: nil,
            relativePath: nil,
            availability: .available
        )
        var status = RepoStatus()
        status.branch.head = "main"
        status.branch.upstream = "origin/main"
        status.branch.ahead = ahead
        status.pushAccess = pushAccess
        return PushToOriginCandidate(repository: repository, status: status)
    }
}
