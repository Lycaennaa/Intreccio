import AppKit
import CryptoKit
import Foundation
import CoreServices
import Security
import Network

nonisolated struct T3CodeWorkspaceActivation: Equatable, Sendable {
    let projectID: String
    let threadID: String
}

nonisolated enum T3CodeApplicationChannel: Hashable, Sendable {
    case latest
    case nightly
    case localBuild

    var menuTitle: String {
        switch self {
        case .latest:
            return "T3 Code"
        case .nightly:
            return "T3 Code (Nightly)"
        case .localBuild:
            return "T3 Code (Local Build)"
        }
    }

    var sortRank: Int {
        switch self {
        case .latest:
            return 0
        case .nightly:
            return 1
        case .localBuild:
            return 2
        }
    }
}

nonisolated struct T3CodeInstalledApplication: Equatable, Sendable {
    let url: URL
    let channel: T3CodeApplicationChannel
    let version: String

    var menuTitle: String {
        channel.menuTitle
    }
}

private nonisolated enum T3CodeSignatureStatus {
    case official
    case local
    case invalid
}

nonisolated enum T3CodeApplicationError: LocalizedError, Sendable {
    case applicationNotInstalled
    case applicationLaunchFailed(String)
    case applicationAlreadyRunning(String)
    case invalidWorkspace
    case workspaceChanged
    case startupTimedOut
    case responseTimedOut
    case socketConnectionFailed(String)
    case invalidSocketResponse(String)
    case projectCreationFailed(String)
    case threadOpenFailed(String)
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationNotInstalled:
            return "T3 Code is not installed."
        case .applicationLaunchFailed(let message):
            return "T3 Code could not be launched: \(message)"
        case .applicationAlreadyRunning(let name):
            return "Cannot open T3 Code while \(name) is already running. Quit it and retry."
        case .invalidWorkspace:
            return "The repository folder is not available."
        case .workspaceChanged:
            return "The repository changed before T3 Code could open it."
        case .startupTimedOut:
            return "T3 Code did not become ready before the startup timeout."
        case .responseTimedOut:
            return "T3 Code did not respond before the request timeout."
        case .socketConnectionFailed(let message):
            return "The T3 Code control socket failed: \(message)"
        case .invalidSocketResponse(let message):
            return "T3 Code returned an invalid activation response: \(message)"
        case .projectCreationFailed(let message):
            return "T3 Code could not create the project: \(message)"
        case .threadOpenFailed(let message):
            return "T3 Code could not open a thread: \(message)"
        case .activationFailed(let message):
            return "T3 Code rejected the request: \(message)"
        }
    }
}

private nonisolated struct T3CodeActivationRequest: Encodable {
    let version: Int
    let requestId: String
    let type: String
    let workspaceRoot: String
    let platform: String
}

private nonisolated struct T3CodeActivationResponse: Decodable {
    let version: Int
    let requestId: String
    let ok: Bool
    let projectID: String?
    let threadID: String?
    let code: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case version
        case requestId
        case ok
        case projectID = "projectId"
        case threadID = "threadId"
        case code
        case message
    }
}

private nonisolated enum T3CodeSocketExchangeError: Error {
    case unavailable
    case responseTimedOut
    case transport(String)
    case invalidResponse(String)
}

private nonisolated final class T3CodeSocketExchange: @unchecked Sendable {
    private static let maximumResponseBytes = 64 * 1_024

    private let connection: NWConnection
    private let request: Data
    private let connectionTimeout: Duration
    private let responseTimeout: Duration
    private let queue = DispatchQueue(label: "com.lycaennaa.intreccio.t3-code-socket")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingResult: Result<Data, Error>?
    private var response = Data()
    private var didBecomeReady = false
    private var didSend = false
    private var finished = false
    private var timeoutTask: Task<Void, Never>?

    init(
        request: Data,
        socketPath: String,
        connectionTimeout: Duration,
        responseTimeout: Duration
    ) {
        self.request = request
        self.connectionTimeout = connectionTimeout
        self.responseTimeout = responseTimeout
        connection = NWConnection(
            to: NWEndpoint.unix(path: socketPath),
            using: NWParameters.tcp
        )
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            lock.lock()
            if let pendingResult {
                lock.unlock()
                resume(continuation, with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(state)
            }
            scheduleTimeout(for: connectionTimeout)
            lock.lock()
            let shouldStart = !finished
            lock.unlock()
            guard shouldStart else { return }
            connection.start(queue: queue)
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func scheduleTimeout(for duration: Duration) {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                self?.timedOut()
            } catch {
            }
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        let previousTask = timeoutTask
        timeoutTask = task
        lock.unlock()
        previousTask?.cancel()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.lock()
            guard !finished, !didSend else {
                lock.unlock()
                return
            }
            didBecomeReady = true
            didSend = true
            lock.unlock()
            scheduleTimeout(for: responseTimeout)

            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    complete(.failure(T3CodeSocketExchangeError.transport(error.localizedDescription)))
                    return
                }
                receive()
            })
        case .failed(let error):
            lock.lock()
            let ready = didBecomeReady
            lock.unlock()
            complete(
                .failure(
                    ready
                        ? T3CodeSocketExchangeError.transport(error.localizedDescription)
                        : T3CodeSocketExchangeError.unavailable
                )
            )
        case .cancelled:
            complete(.failure(T3CodeSocketExchangeError.transport("The socket was closed.")))
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            complete(.failure(T3CodeSocketExchangeError.transport("The socket entered an unknown state.")))
        }
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumResponseBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                complete(.failure(T3CodeSocketExchangeError.transport(error.localizedDescription)))
                return
            }
            if let data, !data.isEmpty {
                switch append(data) {
                case .line(let line):
                    complete(.success(line))
                    return
                case .tooLarge:
                    complete(.failure(T3CodeSocketExchangeError.invalidResponse("The response was too large.")))
                    return
                case .incomplete:
                    break
                }
            }
            if isComplete {
                complete(
                    .failure(
                        T3CodeSocketExchangeError.invalidResponse(
                            "The socket closed before a complete response was received."
                        )
                    )
                )
                return
            }
            receive()
        }
    }

    private enum AppendResult {
        case incomplete
        case line(Data)
        case tooLarge
    }

    private func append(_ data: Data) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return .incomplete }
        response.append(data)
        guard response.count <= Self.maximumResponseBytes else { return .tooLarge }
        guard let newline = response.firstIndex(of: 0x0A) else { return .incomplete }
        return .line(Data(response[..<newline]))
    }

    private func timedOut() {
        lock.lock()
        let ready = didBecomeReady
        lock.unlock()
        complete(
            .failure(
                ready
                    ? T3CodeSocketExchangeError.responseTimedOut
                    : T3CodeSocketExchangeError.unavailable
            )
        )
    }

    private func complete(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let timeoutTask = self.timeoutTask
        lock.unlock()

        timeoutTask?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let continuation {
            resume(continuation, with: result)
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<Data, Error>,
        with result: Result<Data, Error>
    ) {
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private nonisolated final class T3CodeLaunchWaiter: @unchecked Sendable {
    private let timeout: Duration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(timeout: Duration) {
        self.timeout = timeout
    }

    @MainActor
    func run(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let pendingResult {
                lock.unlock()
                resume(continuation, with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
            scheduleTimeout()
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] application, error in
                if let error {
                    self?.complete(
                        .failure(T3CodeApplicationError.applicationLaunchFailed(error.localizedDescription))
                    )
                    return
                }
                guard self?.complete(.success(())) == true else { return }
                application?.activate(options: [.activateAllWindows])
            }
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func scheduleTimeout() {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.timeout ?? .zero)
                self?.complete(.failure(T3CodeApplicationError.startupTimedOut))
            } catch {
            }
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    @discardableResult
    private func complete(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let timeoutTask = self.timeoutTask
        lock.unlock()

        timeoutTask?.cancel()
        if let continuation {
            resume(continuation, with: result)
        }
        return true
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

@MainActor
final class T3CodeApplicationService {
    static let shared = T3CodeApplicationService()
    private var activationInProgress = false
    private var activationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var activationWaiterOrder: [UUID] = []

    nonisolated private static let bundleIdentifier = "com.t3tools.t3code"
    nonisolated private static let startupTimeout: Duration = .seconds(15)
    nonisolated private static let socketAttemptTimeout: Duration = .seconds(1)
    nonisolated private static let responseTimeout: Duration = .seconds(20)
    nonisolated private static let officialTeamIdentifier = "ARK85ZXQ4Z"
    nonisolated private static let nightlyVersionPattern = #"-nightly\.\d{8}\.\d+$"#

    private func acquireActivationSlot() async throws {
        try Task.checkCancellation()
        guard activationInProgress else {
            activationInProgress = true
            return
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                activationWaiters[waiterID] = continuation
                activationWaiterOrder.append(waiterID)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelActivationWaiter(waiterID)
            }
        })
        guard acquired else { throw CancellationError() }
        do {
            try Task.checkCancellation()
        } catch {
            releaseActivationSlot()
            throw error
        }
    }

    private func cancelActivationWaiter(_ waiterID: UUID) {
        guard let continuation = activationWaiters.removeValue(forKey: waiterID) else { return }
        activationWaiterOrder.removeAll { $0 == waiterID }
        continuation.resume(returning: false)
    }

    private func releaseActivationSlot() {
        while let waiterID = activationWaiterOrder.first {
            activationWaiterOrder.removeFirst()
            guard let continuation = activationWaiters.removeValue(forKey: waiterID) else { continue }
            continuation.resume(returning: true)
            return
        }
        activationInProgress = false
    }

    func openWorkspace(
        _ repositoryURL: URL,
        expectedResourceID: String,
        in application: T3CodeInstalledApplication? = nil
    ) async throws -> T3CodeWorkspaceActivation {
        try await acquireActivationSlot()
        defer { releaseActivationSlot() }
        let workspaceURL = repositoryURL.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard workspaceURL.isFileURL,
              workspaceURL.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw T3CodeApplicationError.invalidWorkspace
        }
        guard ResourceIdentity.read(from: workspaceURL) == expectedResourceID else {
            throw T3CodeApplicationError.workspaceChanged
        }
        let selectedApplication: T3CodeInstalledApplication?
        if let application {
            selectedApplication = Self.currentApplication(matching: application)
        } else {
            selectedApplication = Self.installedApplications().first
        }
        guard let selectedApplication else {
            throw T3CodeApplicationError.applicationNotInstalled
        }
        try ensureApplication(selectedApplication)
        try ensureNoConflictingRunningApplication(for: selectedApplication)
        let applicationURL = selectedApplication.url

        let requestID = UUID().uuidString
        let request = T3CodeActivationRequest(
            version: 1,
            requestId: requestID,
            type: "open-workspace",
            workspaceRoot: workspaceURL.path,
            platform: "darwin"
        )
        let requestData = try JSONEncoder().encode(request) + Data([0x0A])
        let socketPath = Self.socketPath(
            stateDirectory: Self.defaultStateDirectory,
            temporaryDirectory: Self.temporaryDirectory,
            userID: UInt32(getuid())
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.startupTimeout)
        try await launchApplication(at: applicationURL, timeout: deadline - clock.now)
        try ensureApplication(selectedApplication)
        try ensureNoConflictingRunningApplication(for: selectedApplication)
        try ensureWorkspace(at: workspaceURL, expectedResourceID: expectedResourceID)
        let responseData = try await exchangeWhenAvailable(
            requestData: requestData,
            socketPath: socketPath,
            workspaceURL: workspaceURL,
            expectedResourceID: expectedResourceID,
            deadline: deadline
        )
        try ensureWorkspace(at: workspaceURL, expectedResourceID: expectedResourceID)
        try ensureApplication(selectedApplication)
        return try Self.validateResponse(responseData, requestID: requestID)
    }

    nonisolated static func installedApplications() -> [T3CodeInstalledApplication] {
        let applications = applicationURLs()
            .filter { !$0.path.hasPrefix("/Volumes/") }
            .compactMap(inspectApplication(at:))
            .sorted { left, right in
                if left.channel.sortRank != right.channel.sortRank {
                    return left.channel.sortRank < right.channel.sortRank
                }
                if left.version != right.version {
                    return versionIsNewer(left.version, than: right.version)
                }
                return left.url.path < right.url.path
            }
        var seenOfficialChannels = Set<T3CodeApplicationChannel>()
        return applications.filter { application in
            guard application.channel == .localBuild else {
                return seenOfficialChannels.insert(application.channel).inserted
            }
            return true
        }
    }

    private nonisolated static func currentApplication(
        matching application: T3CodeInstalledApplication
    ) -> T3CodeInstalledApplication? {
        currentApplication(matching: application, among: installedApplications())
    }

    nonisolated static func currentApplication(
        matching application: T3CodeInstalledApplication,
        among installedApplications: [T3CodeInstalledApplication]
    ) -> T3CodeInstalledApplication? {
        installedApplications.first { installedApplication in
            installedApplication.url.standardizedFileURL == application.url.standardizedFileURL
                && installedApplication.channel == application.channel
        }
    }

    nonisolated static func versionIsNewer(_ left: String, than right: String) -> Bool {
        let leftComponents = numericVersionComponents(left)
        let rightComponents = numericVersionComponents(right)
        for index in 0..<max(leftComponents.count, rightComponents.count) {
            let leftComponent = index < leftComponents.count ? leftComponents[index] : 0
            let rightComponent = index < rightComponents.count ? rightComponents[index] : 0
            if leftComponent != rightComponent {
                return leftComponent > rightComponent
            }
        }
        return left > right
    }

    private nonisolated static func numericVersionComponents(_ version: String) -> [Int] {
        version.split { !$0.isNumber }.compactMap { Int($0) }
    }

    private nonisolated static func applicationURLs() -> [URL] {
        guard let applications = LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString,
            nil
        ) else {
            return []
        }
        let urls = (applications.takeRetainedValue() as NSArray).compactMap { $0 as? URL }
        return Array(Set(urls)).sorted { $0.path < $1.path }
    }

    private nonisolated static func inspectApplication(at url: URL) -> T3CodeInstalledApplication? {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleIdentifier else { return nil }
        switch signatureStatus(for: url) {
        case .invalid:
            return nil
        case .official:
            let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? ""
            let isNightly = version.range(
                of: nightlyVersionPattern,
                options: .regularExpression
            ) != nil || displayName.localizedCaseInsensitiveContains("nightly")
            let channel: T3CodeApplicationChannel = isNightly ? .nightly : .latest
            return T3CodeInstalledApplication(url: url, channel: channel, version: version)
        case .local:
            let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            return T3CodeInstalledApplication(url: url, channel: .localBuild, version: version)
        }
    }

    private nonisolated static func signatureStatus(for url: URL) -> T3CodeSignatureStatus {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return .invalid
        }

        var information: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        if signingStatus == errSecCSUnsigned {
            return .local
        }
        guard signingStatus == errSecSuccess else { return .invalid }

        guard let information else { return .local }
        let teamIdentifier = (information as NSDictionary)[kSecCodeInfoTeamIdentifier] as? String
        guard teamIdentifier == officialTeamIdentifier else { return .local }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess
            ? .official
            : .invalid
    }

    private func ensureNoConflictingRunningApplication(
        for application: T3CodeInstalledApplication
    ) throws {
        guard let conflictingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first(where: { runningApplication in
                guard let bundleURL = runningApplication.bundleURL else { return true }
                return bundleURL.standardizedFileURL.path != application.url.standardizedFileURL.path
            }) else {
            return
        }
        let name = conflictingApplication.bundleURL.flatMap { bundleURL in
            Self.installedApplications().first(where: {
                $0.url.standardizedFileURL.path == bundleURL.standardizedFileURL.path
            })?.menuTitle
        } ?? "another T3 Code build"
        throw T3CodeApplicationError.applicationAlreadyRunning(name)
    }

    nonisolated static var defaultStateDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3", isDirectory: true)
            .appendingPathComponent("userdata", isDirectory: true)
            .path
    }

    nonisolated static var temporaryDirectory: String {
        guard let value = ProcessInfo.processInfo.environment["TMPDIR"], !value.isEmpty else {
            return FileManager.default.temporaryDirectory.path
        }
        return value
    }

    nonisolated static func socketPath(
        stateDirectory: String,
        temporaryDirectory: String,
        userID: UInt32
    ) -> String {
        let digest = SHA256.hash(data: Data(stateDirectory.utf8))
        let stateHash = digest.prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return URL(fileURLWithPath: temporaryDirectory)
            .appendingPathComponent("t3code-\(userID)", isDirectory: true)
            .appendingPathComponent("\(stateHash).sock")
            .path
    }

    nonisolated static func validateResponse(
        _ data: Data,
        requestID: String
    ) throws -> T3CodeWorkspaceActivation {
        guard let response = try? JSONDecoder().decode(T3CodeActivationResponse.self, from: data) else {
            throw T3CodeApplicationError.invalidSocketResponse("The response was not valid JSON.")
        }
        guard response.version == 1, response.requestId == requestID else {
            throw T3CodeApplicationError.invalidSocketResponse("The response did not match the request.")
        }
        if response.ok {
            guard let projectID = nonEmpty(response.projectID),
                  let threadID = nonEmpty(response.threadID) else {
                throw T3CodeApplicationError.invalidSocketResponse(
                    "The successful response did not include a project and thread."
                )
            }
            return T3CodeWorkspaceActivation(projectID: projectID, threadID: threadID)
        }

        guard let code = response.code,
              let message = nonEmpty(response.message) else {
            throw T3CodeApplicationError.invalidSocketResponse("The failure response was incomplete.")
        }
        switch code {
        case "project-create-failed":
            throw T3CodeApplicationError.projectCreationFailed(message)
        case "thread-open-failed":
            throw T3CodeApplicationError.threadOpenFailed(message)
        case "invalid-request", "renderer-unavailable", "environment-unavailable", "platform-mismatch", "request-timeout", "internal-error":
            throw T3CodeApplicationError.activationFailed(message)
        default:
            throw T3CodeApplicationError.invalidSocketResponse("The failure response contained an unknown error code.")
        }
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureWorkspace(at url: URL, expectedResourceID: String) throws {
        guard ResourceIdentity.read(from: url) == expectedResourceID else {
            throw T3CodeApplicationError.workspaceChanged
        }
    }
    private func ensureApplication(_ application: T3CodeInstalledApplication) throws {
        guard Self.currentApplication(matching: application) != nil else {
            throw T3CodeApplicationError.applicationNotInstalled
        }
    }

    private func launchApplication(at applicationURL: URL, timeout: Duration) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.allowsRunningApplicationSubstitution = false
        let waiter = T3CodeLaunchWaiter(timeout: timeout)
        try await withTaskCancellationHandler(operation: {
            try await waiter.run(at: applicationURL, configuration: configuration)
        }, onCancel: {
            waiter.cancel()
        })
    }

    private func exchangeWhenAvailable(
        requestData: Data,
        socketPath: String,
        workspaceURL: URL,
        expectedResourceID: String,
        deadline: ContinuousClock.Instant
    ) async throws -> Data {
        let clock = ContinuousClock()
        while true {
            try Task.checkCancellation()
            try ensureWorkspace(at: workspaceURL, expectedResourceID: expectedResourceID)
            let remaining = deadline - clock.now
            guard remaining > .zero else { throw T3CodeApplicationError.startupTimedOut }
            do {
                return try await exchange(
                    requestData: requestData,
                    socketPath: socketPath,
                    connectionTimeout: min(Self.socketAttemptTimeout, remaining),
                    responseTimeout: min(Self.responseTimeout, remaining)
                )
            } catch let error as T3CodeSocketExchangeError {
                switch error {
                case .unavailable:
                    break
                case .responseTimedOut:
                    throw T3CodeApplicationError.responseTimedOut
                case .transport(let message):
                    throw T3CodeApplicationError.socketConnectionFailed(message)
                case .invalidResponse(let message):
                    throw T3CodeApplicationError.invalidSocketResponse(message)
                }
            }
            let sleepDuration = min(.milliseconds(100), deadline - clock.now)
            guard sleepDuration > .zero else { throw T3CodeApplicationError.startupTimedOut }
            try await Task.sleep(for: sleepDuration)
        }
    }

    private func exchange(
        requestData: Data,
        socketPath: String,
        connectionTimeout: Duration,
        responseTimeout: Duration
    ) async throws -> Data {
        let exchange = T3CodeSocketExchange(
            request: requestData,
            socketPath: socketPath,
            connectionTimeout: connectionTimeout,
            responseTimeout: responseTimeout
        )
        return try await withTaskCancellationHandler {
            try await exchange.run()
        } onCancel: {
            exchange.cancel()
        }
    }
}