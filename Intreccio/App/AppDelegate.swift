import AppKit
import Darwin

struct SingleInstanceLock {
    enum Result {
        case acquired(SingleInstanceLock)
        case alreadyRunning
        case failed(String)
    }

    private let fileDescriptor: Int32

    static func acquire(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result {
        let isHostedTest = environment["XCTestConfigurationFilePath"] != nil
            && NSClassFromString("XCTestCase") != nil
        let isIntegrationTestChild = environment["INTRECCIO_TEST_INSTANCE"] == "1"
            && environment["XCTestConfigurationFilePath"] != nil
        if isHostedTest || isIntegrationTestChild {
            return .acquired(SingleInstanceLock(fileDescriptor: -1))
        }

        let identifier = Bundle.main.bundleIdentifier ?? "com.lycaennaa.intreccio"
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).single-instance.lock")
        let fileDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            return .failed("Unable to open single-instance lock: \(String(cString: strerror(errno)))")
        }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            Darwin.close(fileDescriptor)
            if lockError == EWOULDBLOCK { return .alreadyRunning }
            return .failed("Unable to acquire single-instance lock: \(String(cString: strerror(lockError)))")
        }
        return .acquired(SingleInstanceLock(fileDescriptor: fileDescriptor))
    }

    func keepAlive() {
        _ = fileDescriptor
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum TerminationAttempt {
        case idle
        case prompting
        case waiting(requestID: UUID, sender: NSApplication)
        case flushing(requestID: UUID, sender: NSApplication)
        case terminating
    }

    var mainWindowController: MainWindowController?
    private var terminationAttempt: TerminationAttempt = .idle
    private var mutationCompletionTask: Task<Void, Never>?
    private var terminationTimeoutTask: Task<Void, Never>?
    private let mutationWaitTimeout: Duration
    private let terminationReplyHandler: @MainActor (NSApplication, Bool) -> Void

    init(
        mutationWaitTimeout: Duration = .seconds(120),
        terminationReplyHandler: (@MainActor (NSApplication, Bool) -> Void)? = nil
    ) {
        self.mutationWaitTimeout = mutationWaitTimeout
        self.terminationReplyHandler = terminationReplyHandler ?? { application, shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let windowController = MainWindowController(coordinator: AppCoordinator())
        mainWindowController = windowController
        configureMainMenu(target: windowController.commandRouter)
        windowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let mainWindowController else { return .terminateNow }
        guard case .idle = terminationAttempt else { return .terminateLater }
        terminationAttempt = .prompting
        if mainWindowController.hasActiveMutation || mutationCompletionTask != nil {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Git operation in progress"
            alert.informativeText = "Wait for the operation to finish before quitting. "
                + "If it takes longer than two minutes, quit is canceled and the app stays open."
            alert.addButton(withTitle: "Wait and Quit")
            alert.addButton(withTitle: "Cancel Quit")
            guard let window = mainWindowController.window else {
                terminationAttempt = .idle
                return .terminateCancel
            }
            let replyToApplication = terminationReplyHandler
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else {
                    self?.cancelTerminationPrompt()
                    replyToApplication(sender, false)
                    return
                }
                guard let self else {
                    replyToApplication(sender, false)
                    return
                }
                guard case .prompting = self.terminationAttempt else { return }
                self.waitForMutationAndTerminate(mainWindowController, sender: sender)
            }
            return .terminateLater
        }
        mainWindowController.closeMutationAdmission()
        let requestID = UUID()
        terminationAttempt = .flushing(requestID: requestID, sender: sender)
        Task {
            let saved = await mainWindowController.flushState()
            guard case .flushing(let activeID, let activeSender) = terminationAttempt,
                  activeID == requestID else { return }
            if saved {
                terminationAttempt = .terminating
            } else {
                terminationAttempt = .idle
                mainWindowController.reopenMutationAdmission()
            }
            reply(to: activeSender, shouldTerminate: saved)
        }
        return .terminateLater
    }

    private func waitForMutationAndTerminate(
        _ windowController: MainWindowController,
        sender: NSApplication
    ) {
        windowController.closeMutationAdmission()
        let requestID = UUID()
        terminationAttempt = .waiting(requestID: requestID, sender: sender)
        terminationTimeoutTask?.cancel()
        let timeout = mutationWaitTimeout
        terminationTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  case .waiting(let activeID, let activeSender) = self.terminationAttempt,
                  activeID == requestID else { return }
            self.terminationAttempt = .idle
            self.terminationTimeoutTask = nil
            reply(to: activeSender, shouldTerminate: false)
        }
        guard mutationCompletionTask == nil else { return }
        mutationCompletionTask = Task { [weak self] in
            let operationSucceeded = await windowController.waitForMutation()
            guard let self else { return }
            self.mutationCompletionTask = nil
            guard case .waiting(let activeID, let activeSender) = self.terminationAttempt else {
                windowController.reopenMutationAdmission()
                return
            }
            self.terminationTimeoutTask?.cancel()
            self.terminationTimeoutTask = nil
            guard operationSucceeded else {
                self.terminationAttempt = .idle
                windowController.reopenMutationAdmission()
                reply(to: activeSender, shouldTerminate: false)
                return
            }
            self.terminationAttempt = .flushing(requestID: activeID, sender: activeSender)
            let saved = await windowController.flushState()
            guard case .flushing(let currentID, let currentSender) = self.terminationAttempt,
                  currentID == activeID else { return }
            if saved {
                self.terminationAttempt = .terminating
            } else {
                self.terminationAttempt = .idle
                windowController.reopenMutationAdmission()
            }
            reply(to: currentSender, shouldTerminate: saved)
        }
    }

    private func cancelTerminationPrompt() {
        guard case .prompting = terminationAttempt else { return }
        terminationAttempt = .idle
    }

    private func reply(to sender: NSApplication, shouldTerminate: Bool) {
        terminationReplyHandler(sender, shouldTerminate)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainWindowController?.rescanIfLoaded()
    }

    func configureMainMenu(target: MainWindowCommandRouter) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Intreccio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        addItem(to: fileMenu, title: "Add Repository…", action: #selector(MainWindowCommandRouter.addRepository(_:)), key: "o", target: target)
        addItem(to: fileMenu, title: "Clone Repository…", action: #selector(MainWindowCommandRouter.cloneRepository(_:)), key: "", target: target)
        addItem(to: fileMenu, title: "Create Local Repository…", action: #selector(MainWindowCommandRouter.createLocalRepository(_:)), key: "", target: target)
        addItem(to: fileMenu, title: "Downloads", action: #selector(MainWindowCommandRouter.showDownloads(_:)), key: "", target: target)
        let addFolder = fileMenu.addItem(withTitle: "Add Root Folder…", action: #selector(MainWindowCommandRouter.addFolder(_:)), keyEquivalent: "o")
        addFolder.target = target
        addFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Refresh Repository", action: #selector(MainWindowCommandRouter.refresh(_:)), key: "r", target: target)
        addItem(to: fileMenu, title: "Rescan All Sources", action: #selector(MainWindowCommandRouter.rescan(_:)), key: "r", modifiers: [.command, .shift], target: target)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        addItem(to: viewMenu, title: "Focus Search", action: #selector(MainWindowCommandRouter.focusSearch(_:)), key: "f", target: target)
        addItem(to: viewMenu, title: "Find in Diff", action: #selector(MainWindowCommandRouter.focusDiffSearch(_:)), key: "f", modifiers: [.command, .option], target: target)
        addItem(to: viewMenu, title: "Previous Diff Hunk", action: #selector(MainWindowCommandRouter.previousDiffHunk(_:)), key: "[", modifiers: [.command, .option], target: target)
        addItem(to: viewMenu, title: "Next Diff Hunk", action: #selector(MainWindowCommandRouter.nextDiffHunk(_:)), key: "]", modifiers: [.command, .option], target: target)
        addItem(to: viewMenu, title: "Previous Diff File", action: #selector(MainWindowCommandRouter.previousDiffFile(_:)), key: ",", modifiers: [.command, .option], target: target)
        addItem(to: viewMenu, title: "Next Diff File", action: #selector(MainWindowCommandRouter.nextDiffFile(_:)), key: ".", modifiers: [.command, .option], target: target)
        addItem(to: viewMenu, title: "Focus Repositories", action: #selector(MainWindowCommandRouter.focusRepositories(_:)), key: "l", target: target)
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, title: "Show Changes", action: #selector(MainWindowCommandRouter.showChanges(_:)), key: "1", target: target)
        addItem(to: viewMenu, title: "Show History", action: #selector(MainWindowCommandRouter.showHistory(_:)), key: "2", target: target)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.control, .command]
        viewItem.submenu = viewMenu

        let repositoryItem = NSMenuItem()
        mainMenu.addItem(repositoryItem)
        let repositoryMenu = NSMenu(title: "Repository")
        addItem(to: repositoryMenu, title: "Stage Selected", action: #selector(MainWindowCommandRouter.stageSelected(_:)), key: "s", target: target)
        addItem(to: repositoryMenu, title: "Stage All", action: #selector(MainWindowCommandRouter.stageAll(_:)), key: "s", modifiers: [.command, .shift], target: target)
        addItem(to: repositoryMenu, title: "Unstage Selected", action: #selector(MainWindowCommandRouter.unstageSelected(_:)), key: "s", modifiers: [.command, .option], target: target)
        addItem(to: repositoryMenu, title: "Unstage All", action: #selector(MainWindowCommandRouter.unstageAll(_:)), key: "s", modifiers: [.command, .option, .shift], target: target)
        repositoryMenu.addItem(.separator())
        let stashChanges = repositoryMenu.addItem(withTitle: "Stash All Changes", action: #selector(MainWindowCommandRouter.stashChanges(_:)), keyEquivalent: "")
        stashChanges.target = target
        let restoreStash = repositoryMenu.addItem(withTitle: "Restore Latest Stash", action: #selector(MainWindowCommandRouter.restoreLatestStash(_:)), keyEquivalent: "")
        restoreStash.target = target
        repositoryMenu.addItem(.separator())
        addItem(to: repositoryMenu, title: "Commit", action: #selector(MainWindowCommandRouter.commit(_:)), key: "\r", target: target)
        repositoryItem.submenu = repositoryMenu
        NSApp.mainMenu = mainMenu
    }

    private func addItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
    }
}
