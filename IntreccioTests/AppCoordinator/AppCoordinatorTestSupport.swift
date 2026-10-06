import AppKit
import Foundation
import XCTest
@testable import Intreccio

@MainActor
extension AppCoordinatorTests {

    func makeCoordinator(stateFile: URL) -> AppCoordinator {
        let coordinator = AppCoordinator(stateStore: StateStore(fileURL: stateFile))
        addTeardownBlock { [coordinator] in
            _ = await coordinator.shutdown()
        }
        return coordinator
    }


    func initializeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(at: url, arguments: ["init", "-b", "main"])
    }


    func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outlineView = view as? NSOutlineView { return outlineView }
        for subview in view.subviews {
            if let outlineView = findOutlineView(in: subview) { return outlineView }
        }
        return nil
    }


}

actor TaskCleanupProbe {
    private(set) var started = false
    private(set) var finished = false

    func markStarted() { started = true }
    func markFinished() { finished = true }
}
