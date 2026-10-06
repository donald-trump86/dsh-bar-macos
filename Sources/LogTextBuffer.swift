import Foundation

/// Only complete, redacted lines reach the display buffer. Byte limits also
/// bound incomplete lines and text made of arbitrarily large grapheme clusters.
struct LogTextBuffer {
    private(set) var text = ""
    private var pending = Data()
    private var discardingLine = false
    private let maximumLineBytes: Int
    private let maximumBufferedBytes: Int

    init(maximumLineBytes: Int = 512 * 1024, maximumBufferedBytes: Int = 1_000_000) {
        precondition(maximumLineBytes > 0 && maximumBufferedBytes > 0)
        self.maximumLineBytes = maximumLineBytes
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    /// A seek, rotation or Clear must not join unrelated fragments into a URL.
    mutating func reset(discardPartialLine: Bool) {
        pending.removeAll(keepingCapacity: false)
        discardingLine = discardPartialLine
    }

    static func startsMidLine(handle: FileHandle, offset: UInt64) throws -> Bool {
        // Byte rotation can start a new inode inside a token. A file head is
        // unverified too; only a preceding newline proves a safe line boundary.
        guard offset > 0 else { return true }
        try handle.seek(toOffset: offset - 1)
        return try handle.read(upToCount: 1) != Data([10])
    }

    mutating func append(_ data: Data, redacting: (String) -> String) {
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 10)
            let end = newline.map { data.index(after: $0) } ?? data.endIndex
            if !discardingLine {
                if pending.count + data.distance(from: start, to: end) > maximumLineBytes {
                    // ponytail: omit oversized/incomplete lines rather than risk
                    // revealing a token fragment; safe progressive previews can wait.
                    pending.removeAll(keepingCapacity: false)
                    discardingLine = true
                } else {
                    pending.append(data[start..<end])
                    if newline != nil {
                        text.append(redacting(String(decoding: pending, as: UTF8.self)))
                        pending.removeAll(keepingCapacity: true)
                        trimDisplay()
                    }
                }
            }
            if newline != nil { discardingLine = false }
            start = end
        }
    }

    private mutating func trimDisplay() {
        guard text.utf8.count > maximumBufferedBytes else { return }
        let tail = Data(text.utf8).suffix(maximumBufferedBytes)
        // Keep a scalar boundary, not an arbitrary UTF-8 continuation byte.
        let start = tail.firstIndex { $0 & 0xC0 != 0x80 } ?? tail.endIndex
        text = String(decoding: tail[start...], as: UTF8.self)
    }
}
