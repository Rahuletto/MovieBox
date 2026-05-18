import Foundation

enum TrackerEncoding {
    /// BEP-3: `info_hash` is 20 raw bytes, each encoded as `%XX` in the query string.
    static func percentEncodeInfoHash(hex: String) -> String {
        var result = ""
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard nextIndex > index,
                  let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                index = nextIndex
                continue
            }
            result += String(format: "%%%02X", byte)
            index = nextIndex
        }
        return result
    }
}
