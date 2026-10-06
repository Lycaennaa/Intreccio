import AppKit
import Darwin

let instanceLock: SingleInstanceLock
switch SingleInstanceLock.acquire() {
case let .acquired(lock):
    instanceLock = lock
case .alreadyRunning:
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.activate()
    }
    Darwin.exit(EXIT_SUCCESS)
case let .failed(message):
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.setActivationPolicy(.regular)
application.delegate = appDelegate
withExtendedLifetime(appDelegate) {
    instanceLock.keepAlive()
    application.run()
}
