import Foundation
import XCTest

private let testTemporaryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".test-tmp", isDirectory: true)

extension XCTestCase {
    func makeTestDirectory() throws -> URL {
        let directory = testTemporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

func makeApplicationBundle(at url: URL, executableIsDirectory: Bool = false) throws {
    let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
    let executableDirectoryURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executableDirectoryURL, withIntermediateDirectories: true)
    let executableURL = executableDirectoryURL.appendingPathComponent("Editor")
    if executableIsDirectory {
        try FileManager.default.createDirectory(at: executableURL, withIntermediateDirectories: true)
    } else {
        try Data().write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    }
    let info: [String: String] = [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "Editor",
        "CFBundleIdentifier": "com.example.editor.\(UUID().uuidString)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Editor",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
}
