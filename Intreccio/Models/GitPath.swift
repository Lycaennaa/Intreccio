import Foundation

nonisolated enum GitPathLossiness: String, Sendable, Equatable {
    case exact
    case lossy
}

nonisolated struct GitPath: Sendable, Equatable, Hashable {
    let bytes: Data
    let lossiness: GitPathLossiness

    init(_ value: String) {
        bytes = Data(value.utf8)
        lossiness = .exact
    }

    init(bytes: Data) {
        self.bytes = bytes
        lossiness = String(data: bytes, encoding: .utf8) == nil ? .lossy : .exact
    }

    var decodedString: String {
        String(decoding: bytes, as: UTF8.self)
    }

    var isLossy: Bool {
        lossiness == .lossy
    }

    var isAddressable: Bool {
        !isLossy && relativeComponents != nil
    }

    var isFileActionAddressable: Bool {
        !isLossy && RepositoryPathPolicy.relativePathComponents(decodedString) != nil
    }

    var isIgnoreAddressable: Bool {
        let path = hasTrailingSlash ? GitPath(bytes: Data(bytes.dropLast())) : self
        return path.isFileActionAddressable
    }

    var byteCount: Int {
        bytes.count
    }

    var hasTrailingSlash: Bool {
        bytes.last == 0x2F
    }

    var displayString: String {
        var result = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                appendDisplayScalar(UnicodeScalar(byte), to: &result)
                index += 1
            } else if let decoded = decodeUTF8Scalar(at: index) {
                appendDisplayScalar(decoded.scalar, to: &result)
                index += decoded.length
            } else {
                result += String(format: "\\x%02X", byte)
                index += 1
            }
        }
        return result
    }

    var relativeComponents: [Data]? {
        guard !bytes.isEmpty, bytes.first != 0x2F, !bytes.contains(0) else { return nil }
        let end = hasTrailingSlash ? bytes.count - 1 : bytes.count
        guard end > 0 else { return nil }
        var components: [Data] = []
        var start = 0
        for index in 0..<end where bytes[index] == 0x2F {
            components.append(Data(bytes[start..<index]))
            start = index + 1
        }
        components.append(Data(bytes[start..<end]))
        guard !components.contains(where: { component in
            component.isEmpty || component == Data(".".utf8) || component == Data("..".utf8)
        }) else { return nil }
        return components
    }

    func isDescendant(of folder: GitPath) -> Bool {
        guard let pathComponents = relativeComponents,
              let folderComponents = folder.relativeComponents,
              pathComponents.count > folderComponents.count else { return false }
        return pathComponents.starts(with: folderComponents)
    }

    var literalPathspecData: Data {
        var result = Data(":(literal)".utf8)
        result.append(bytes)
        return result
    }

    private func appendDisplayScalar(_ scalar: UnicodeScalar, to result: inout String) {
        switch scalar.value {
        case 0x5C: result += "\\\\"
        case 0x0A: result += "\\n"
        case 0x0D: result += "\\r"
        case 0x09: result += "\\t"
        default:
            if [.control, .format, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory) {
                result += String(format: "\\u{%04X}", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private func decodeUTF8Scalar(at index: Int) -> (scalar: UnicodeScalar, length: Int)? {
        let first = bytes[index]
        let length: Int
        let minimum: UInt32
        let value: UInt32
        switch first {
        case 0xC2...0xDF:
            length = 2
            minimum = 0x80
            value = UInt32(first & 0x1F)
        case 0xE0...0xEF:
            length = 3
            minimum = 0x800
            value = UInt32(first & 0x0F)
        case 0xF0...0xF4:
            length = 4
            minimum = 0x10000
            value = UInt32(first & 0x07)
        default:
            return nil
        }
        guard index + length <= bytes.count else { return nil }
        var scalarValue = value
        for offset in 1..<length {
            let next = bytes[index + offset]
            guard next & 0xC0 == 0x80 else { return nil }
            scalarValue = (scalarValue << 6) | UInt32(next & 0x3F)
        }
        guard scalarValue >= minimum,
              scalarValue <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(scalarValue),
              let scalar = UnicodeScalar(scalarValue) else { return nil }
        return (scalar, length)
    }
}
