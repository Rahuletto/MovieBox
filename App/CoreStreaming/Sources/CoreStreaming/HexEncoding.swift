import Foundation

enum HexEncoding {
    /// Parses a hex string (optional `0x` prefix) into raw bytes. Returns empty data on invalid input.
    static func data(fromHex hex: String) -> Data {
        let normalized = hex.hasPrefix("0x") || hex.hasPrefix("0X")
            ? String(hex.dropFirst(2))
            : hex
        var result = Data()
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2, limitedBy: normalized.endIndex) ?? normalized.endIndex
            guard next > index, let byte = UInt8(normalized[index..<next], radix: 16) else {
                index = next
                continue
            }
            result.append(byte)
            index = next
        }
        return result
    }
}
