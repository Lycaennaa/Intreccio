import Foundation

@MainActor
extension AppCoordinator {
    func restoreSources() async {
        do {
            try await catalog.restoreSources()
            if !isShuttingDown { clearStateSaveError() }
        } catch is CancellationError {
        } catch {
            guard !isShuttingDown else { return }
            setStateSaveError("Sources loaded, but updated state could not be saved: \(error)")
        }
    }
}
