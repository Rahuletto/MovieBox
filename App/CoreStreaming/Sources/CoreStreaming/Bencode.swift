import Foundation

// MARK: - Bencode Value

public indirect enum BencodeValue: Equatable, Hashable {
    case string(Data)
    case integer(Int64)
    case list([BencodeValue])
    case dictionary([String: BencodeValue])

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let data):
            hasher.combine(0)
            hasher.combine(data)
        case .integer(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .list(let values):
            hasher.combine(2)
            hasher.combine(values)
        case .dictionary(let dict):
            hasher.combine(3)
            for key in dict.keys.sorted() {
                hasher.combine(key)
                hasher.combine(dict[key])
            }
        }
    }
}

// MARK: - Bencode Parser

public enum BencodeParser {
    public enum Error: Swift.Error {
        case invalidData(String)
        case unexpectedEnd
        case invalidInteger
        case invalidLength
    }

    public static func parse(_ data: Data) throws -> BencodeValue {
        var index = data.startIndex
        return try parseValue(data, at: &index)
    }

    public static func encode(_ value: BencodeValue) -> Data {
        var data = Data()
        encodeValue(value, into: &data)
        return data
    }

    private static func parseValue(_ data: Data, at index: inout Data.Index) throws -> BencodeValue {
        guard index < data.endIndex else {
            throw Error.unexpectedEnd
        }

        let byte = data[index]
        switch byte {
        case UInt8(ascii: "i"):
            return try parseInteger(data, at: &index)
        case UInt8(ascii: "l"):
            return try parseList(data, at: &index)
        case UInt8(ascii: "d"):
            return try parseDictionary(data, at: &index)
        case let b where b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"):
            return try parseString(data, at: &index)
        default:
            throw Error.invalidData("Unexpected byte: \(byte)")
        }
    }

    private static func parseInteger(_ data: Data, at index: inout Data.Index) throws -> BencodeValue {
        guard data[index] == UInt8(ascii: "i") else {
            throw Error.invalidData("Expected 'i' for integer")
        }
        index += 1

        var end = index
        while end < data.endIndex, data[end] != UInt8(ascii: "e") {
            end += 1
        }
        guard end < data.endIndex else {
            throw Error.unexpectedEnd
        }

        let intData = data[index..<end]
        guard let string = String(data: intData, encoding: .ascii),
              let value = Int64(string) else {
            throw Error.invalidInteger
        }

        index = end + 1
        return .integer(value)
    }

    private static func parseString(_ data: Data, at index: inout Data.Index) throws -> BencodeValue {
        var lengthEnd = index
        while lengthEnd < data.endIndex, data[lengthEnd] != UInt8(ascii: ":") {
            lengthEnd += 1
        }
        guard lengthEnd < data.endIndex else {
            throw Error.unexpectedEnd
        }

        let lengthData = data[index..<lengthEnd]
        guard let lengthString = String(data: lengthData, encoding: .ascii),
              let length = Int(lengthString) else {
            throw Error.invalidLength
        }

        let stringStart = lengthEnd + 1
        let stringEnd = stringStart + length
        guard stringEnd <= data.endIndex else {
            throw Error.unexpectedEnd
        }

        let stringData = data[stringStart..<stringEnd]
        index = stringEnd
        return .string(stringData)
    }

    private static func parseList(_ data: Data, at index: inout Data.Index) throws -> BencodeValue {
        guard data[index] == UInt8(ascii: "l") else {
            throw Error.invalidData("Expected 'l' for list")
        }
        index += 1

        var values: [BencodeValue] = []
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            values.append(try parseValue(data, at: &index))
        }
        guard index < data.endIndex else {
            throw Error.unexpectedEnd
        }
        index += 1

        return .list(values)
    }

    private static func parseDictionary(_ data: Data, at index: inout Data.Index) throws -> BencodeValue {
        guard data[index] == UInt8(ascii: "d") else {
            throw Error.invalidData("Expected 'd' for dictionary")
        }
        index += 1

        var dict: [String: BencodeValue] = [:]
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            let key = try parseValue(data, at: &index)
            guard case .string(let keyData) = key,
                  let keyString = String(data: keyData, encoding: .utf8) else {
                throw Error.invalidData("Dictionary keys must be strings")
            }
            let value = try parseValue(data, at: &index)
            dict[keyString] = value
        }
        guard index < data.endIndex else {
            throw Error.unexpectedEnd
        }
        index += 1

        return .dictionary(dict)
    }

    private static func encodeValue(_ value: BencodeValue, into data: inout Data) {
        switch value {
        case .string(let s):
            data.append(contentsOf: String(s.count).utf8)
            data.append(UInt8(ascii: ":"))
            data.append(s)
        case .integer(let i):
            data.append(UInt8(ascii: "i"))
            data.append(contentsOf: String(i).utf8)
            data.append(UInt8(ascii: "e"))
        case .list(let values):
            data.append(UInt8(ascii: "l"))
            for v in values {
                encodeValue(v, into: &data)
            }
            data.append(UInt8(ascii: "e"))
        case .dictionary(let dict):
            data.append(UInt8(ascii: "d"))
            for key in dict.keys.sorted() {
                encodeValue(.string(Data(key.utf8)), into: &data)
                if let value = dict[key] {
                    encodeValue(value, into: &data)
                }
            }
            data.append(UInt8(ascii: "e"))
        }
    }
}

// MARK: - Convenience Extensions

public extension BencodeValue {
    var string: String? {
        guard case .string(let data) = self else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var integer: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var list: [BencodeValue]? {
        guard case .list(let values) = self else { return nil }
        return values
    }

    var dictionary: [String: BencodeValue]? {
        guard case .dictionary(let dict) = self else { return nil }
        return dict
    }

    subscript(key: String) -> BencodeValue? {
        guard case .dictionary(let dict) = self else { return nil }
        return dict[key]
    }
}
