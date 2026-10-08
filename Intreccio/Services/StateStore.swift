import Foundation

nonisolated enum StateStoreError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case readFailed(String)
    case writeFailed(String)
    case writeBlocked(String)
    case catalogBudgetExceeded(String)
    case uiBudgetExceeded(String)

    var description: String {
        switch self {
        case .unsupportedSchema(let version): "Unsupported state schema version: \(version)"
        case .readFailed(let message): "Could not read saved state: \(message)"
        case .writeFailed(let message): "Could not save state: \(message)"
        case .writeBlocked(let message): "State writes are blocked to preserve existing data: \(message)"
        case .catalogBudgetExceeded(let message): "Catalog persistence budget exceeded: \(message)"
        case .uiBudgetExceeded(let message): "UI state persistence budget exceeded: \(message)"
        }
    }
}

nonisolated struct StateLoadResult: Sendable {
    let state: PersistedState
    let recoveryMessage: String?
}

nonisolated struct StateStoreValidatedCatalog: Sendable {
    fileprivate let catalog: PersistedCatalogState
    fileprivate let data: Data
}

actor StateStore {
    let fileURL: URL
    let uiFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var writesBlockedReason: String?
    private var uiWritesBlockedReason: String?
#if DEBUG
    private(set) var catalogEncodingCountForTesting = 0
#endif

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        uiFileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let resolvedFileURL: URL
        if let fileURL {
            resolvedFileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            resolvedFileURL = support
                .appendingPathComponent("Intreccio", isDirectory: true)
                .appendingPathComponent("state.json")
        }
        self.fileURL = resolvedFileURL
        self.uiFileURL = uiFileURL ?? Self.uiFileURL(for: resolvedFileURL)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> StateLoadResult {
        let catalog = loadCatalog()
        let ui = loadUI(fallback: catalog.state.uiState)
        var state = catalog.state
        state.uiState = ui.state
        let recoveryMessages = [catalog.recoveryMessage, ui.recoveryMessage].compactMap(\.self)
        return StateLoadResult(
            state: state,
            recoveryMessage: recoveryMessages.isEmpty ? nil : recoveryMessages.joined(separator: "\n")
        )
    }

    func save(
        _ state: PersistedState,
        validatedCatalogData: StateStoreValidatedCatalog? = nil
    ) throws {
        try ensureWritesAllowed()
        do {
            let catalogData = try encodedOrValidatedCatalogData(
                for: state,
                validatedCatalogData: validatedCatalogData
            )
            let uiData = try encodedUIData(for: state.uiState)
            let previousCatalog = try catalogContents(at: fileURL)
            let previousUI = try contents(at: uiFileURL)

            try write(uiData, to: uiFileURL)
            do {
                try write(catalogData, to: fileURL)
            } catch {
                var rollbackFailures: [String] = []
                do {
                    try restore(previousCatalog, at: fileURL)
                } catch {
                    rollbackFailures.append("catalog rollback failed: \(error.localizedDescription)")
                }
                do {
                    try restore(previousUI, at: uiFileURL)
                } catch {
                    rollbackFailures.append("UI rollback failed: \(error.localizedDescription)")
                }
                throw StateStoreError.writeFailed(
                    ([error.localizedDescription] + rollbackFailures).joined(separator: "; ")
                )
            }
        } catch let error as StateStoreError {
            throw error
        } catch let error as PersistedCatalogBudgetError {
            throw StateStoreError.catalogBudgetExceeded(error.description)
        } catch let error as PersistedUIStateBudgetError {
            throw StateStoreError.uiBudgetExceeded(error.description)
        } catch {
            throw StateStoreError.writeFailed(error.localizedDescription)
        }
    }

    func validateCatalog(_ state: PersistedState) throws -> StateStoreValidatedCatalog {
        let data = try encodedCatalogData(for: state)
        return StateStoreValidatedCatalog(catalog: PersistedCatalogState(state), data: data)
    }

    func saveUI(_ uiState: PersistedUIState) throws {
        try ensureWritesAllowed()
        do {
            let data = try encodedUIData(for: uiState)
            try write(data, to: uiFileURL)
        } catch let error as StateStoreError {
            throw error
        } catch {
            throw StateStoreError.writeFailed(error.localizedDescription)
        }
    }

    private struct CatalogLoadResult {
        let state: PersistedState
        let recoveryMessage: String?
    }

    private struct UILoadResult {
        let state: PersistedUIState
        let recoveryMessage: String?
    }

    private func loadCatalog() -> CatalogLoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CatalogLoadResult(state: PersistedState(), recoveryMessage: nil)
        }
        let data: Data
        do {
            data = try readCatalogData(at: fileURL)
        } catch let error as PersistedCatalogBudgetError {
            return catalogBudgetFailure(error)
        } catch {
            writesBlockedReason = error.localizedDescription
            return CatalogLoadResult(
                state: PersistedState(),
                recoveryMessage: "Saved state could not be read. It was left untouched and writes are disabled: \(error)"
            )
        }
        do {
            let document = try decoder.decode(PersistedDocumentEnvelope.self, from: data)
            switch document {
            case .unsupportedSchema(let version):
                let error = StateStoreError.unsupportedSchema(version)
                writesBlockedReason = error.description
                return CatalogLoadResult(
                    state: PersistedState(),
                    recoveryMessage: "Saved state uses an unsupported schema and was left untouched. Update the app before continuing: \(error)"
                )
            case .catalog(let catalog):
                let state = catalog.state(with: PersistedUIState())
                try PersistedCatalogBudget.validate(state)
                return CatalogLoadResult(state: state, recoveryMessage: nil)
            case .legacy(let state):
                try PersistedCatalogBudget.validate(state)
                return CatalogLoadResult(state: state, recoveryMessage: nil)
            case .ui:
                throw PersistedDocumentEnvelopeError.unexpectedDocumentType
            }
        } catch let error as PersistedCatalogBudgetError {
            return catalogBudgetFailure(error)
        } catch {
            let quarantineURL = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Self.timestamp()).json")
            do {
                try fileManager.moveItem(at: fileURL, to: quarantineURL)
                writesBlockedReason = nil
                return CatalogLoadResult(
                    state: PersistedState(),
                    recoveryMessage: "Saved state was corrupt and moved to \(quarantineURL.path): \(error)"
                )
            } catch let quarantineError {
                writesBlockedReason = quarantineError.localizedDescription
                return CatalogLoadResult(
                    state: PersistedState(),
                    recoveryMessage: "Saved state is unreadable and could not be quarantined: \(error); \(quarantineError)"
                )
            }
        }
    }

    private func catalogBudgetFailure(_ violation: PersistedCatalogBudgetError) -> CatalogLoadResult {
        let error = StateStoreError.catalogBudgetExceeded(violation.description)
        writesBlockedReason = error.description
        return CatalogLoadResult(
            state: PersistedState(),
            recoveryMessage: "Saved catalog exceeds its persistence budget and was left untouched. Writes are disabled: \(error)"
        )
    }

    private func loadUI(fallback: PersistedUIState) -> UILoadResult {
        guard fileManager.fileExists(atPath: uiFileURL.path) else {
            return UILoadResult(state: fallback, recoveryMessage: nil)
        }
        let data: Data
        do {
            data = try readUIData(at: uiFileURL)
        } catch let error as PersistedUIStateBudgetError {
            let budgetError = StateStoreError.uiBudgetExceeded(error.description)
            uiWritesBlockedReason = budgetError.description
            return UILoadResult(
                state: fallback,
                recoveryMessage: "Saved UI state exceeds its persistence budget and was left untouched. UI writes are disabled: \(budgetError)"
            )
        } catch {
            uiWritesBlockedReason = error.localizedDescription
            return UILoadResult(
                state: fallback,
                recoveryMessage: "Saved UI state could not be read. It was left untouched and UI writes are disabled: \(error)"
            )
        }
        do {
            let document = try decoder.decode(PersistedDocumentEnvelope.self, from: data)
            switch document {
            case .unsupportedSchema(let version):
                let error = StateStoreError.unsupportedSchema(version)
                uiWritesBlockedReason = error.description
                return UILoadResult(
                    state: fallback,
                    recoveryMessage: "Saved UI state uses an unsupported schema and was left untouched. Update the app before continuing: \(error)"
                )
            case .ui(let document):
                return UILoadResult(state: document.uiState, recoveryMessage: nil)
            case .catalog, .legacy:
                throw PersistedDocumentEnvelopeError.unexpectedDocumentType
            }
        } catch {
            let quarantineURL = uiFileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Self.timestamp()).json")
            do {
                try fileManager.moveItem(at: uiFileURL, to: quarantineURL)
                uiWritesBlockedReason = nil
                return UILoadResult(
                    state: fallback,
                    recoveryMessage: "Saved UI state was corrupt and moved to \(quarantineURL.path): \(error)"
                )
            } catch let quarantineError {
                uiWritesBlockedReason = quarantineError.localizedDescription
                return UILoadResult(
                    state: fallback,
                    recoveryMessage: "Saved UI state is unreadable and could not be quarantined: \(error); \(quarantineError)"
                )
            }
        }
    }

    private func ensureWritesAllowed() throws {
        if let writesBlockedReason {
            throw StateStoreError.writeBlocked(writesBlockedReason)
        }
        if let uiWritesBlockedReason {
            throw StateStoreError.writeBlocked(uiWritesBlockedReason)
        }
    }

    private func encodedUIData(for uiState: PersistedUIState) throws -> Data {
        do {
            let data = try encoder.encode(PersistedUIStateDocument(uiState))
            try PersistedUIStateBudget.validateEncodedSize(data.count)
            return data
        } catch let error as PersistedUIStateBudgetError {
            throw StateStoreError.uiBudgetExceeded(error.description)
        }
    }

    private func encodedCatalogData(for state: PersistedState) throws -> Data {
        do {
            try PersistedCatalogBudget.validate(state)
#if DEBUG
            catalogEncodingCountForTesting += 1
#endif
            let data = try encoder.encode(PersistedCatalogState(state))
            try PersistedCatalogBudget.validateEncodedSize(data.count)
            return data
        } catch let error as PersistedCatalogBudgetError {
            throw StateStoreError.catalogBudgetExceeded(error.description)
        }
    }
    private func encodedOrValidatedCatalogData(
        for state: PersistedState,
        validatedCatalogData: StateStoreValidatedCatalog?
    ) throws -> Data {
        let catalog = PersistedCatalogState(state)
        guard let validatedCatalogData,
              validatedCatalogData.catalog == catalog else {
            return try encodedCatalogData(for: state)
        }
        do {
            try PersistedCatalogBudget.validate(state)
            try PersistedCatalogBudget.validateEncodedSize(validatedCatalogData.data.count)
            return validatedCatalogData.data
        } catch let error as PersistedCatalogBudgetError {
            throw StateStoreError.catalogBudgetExceeded(error.description)
        }
    }

    private func catalogContents(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readCatalogData(at: url)
    }

    private func contents(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readUIData(at: url)
    }

    private func readCatalogData(at url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0 else {
            throw StateStoreError.readFailed("Saved catalog size could not be determined.")
        }
        guard fileSize.int64Value <= Int64(PersistedCatalogBudget.maxEncodedBytes) else {
            throw PersistedCatalogBudgetError.encodedSizeExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: PersistedCatalogBudget.maxEncodedBytes + 1) ?? Data()
        try PersistedCatalogBudget.validateEncodedSize(data.count)
        return data
    }
    private func readUIData(at url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value >= 0 else {
            throw StateStoreError.readFailed("Saved UI state size could not be determined.")
        }
        guard fileSize.int64Value <= Int64(PersistedUIStateBudget.maxEncodedBytes) else {
            throw PersistedUIStateBudgetError.encodedSizeExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: PersistedUIStateBudget.maxEncodedBytes + 1) ?? Data()
        try PersistedUIStateBudget.validateEncodedSize(data.count)
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try write(data, to: url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func uiFileURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("ui")
            .appendingPathExtension("json")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
