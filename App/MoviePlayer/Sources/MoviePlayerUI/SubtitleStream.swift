import Foundation

public struct SubtitleCue: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let sequenceNumber: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(sequenceNumber: Int, startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = UUID()
        self.sequenceNumber = sequenceNumber
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

    public func isActive(at time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

public actor SubtitleStream {
    private var cues: [SubtitleCue] = []
    private var currentCueIndex: Int = 0
    private var loadedUpToTime: TimeInterval = 0
    private var isComplete = false

    public init() {}

    public func load(from data: Data) {
        cues = parseSRT(data)
        loadedUpToTime = cues.last?.endTime ?? 0
        isComplete = true
    }

    public func load(from string: String) {
        cues = parseSRTString(string)
        loadedUpToTime = cues.last?.endTime ?? 0
        isComplete = true
    }

    public func cue(at time: TimeInterval) -> SubtitleCue? {
        guard !cues.isEmpty else { return nil }

        if currentCueIndex < cues.count && cues[currentCueIndex].isActive(at: time) {
            return cues[currentCueIndex]
        }

        let nextIndex = cues.firstIndex { $0.isActive(at: time) }
        if let idx = nextIndex {
            currentCueIndex = idx
            return cues[idx]
        }

        return nil
    }

    public func upcomingCues(after time: TimeInterval, count: Int = 3) -> [SubtitleCue] {
        cues
            .filter { $0.startTime > time && $0.startTime <= time + 30 }
            .prefix(count)
            .map { $0 }
    }

    public var totalCues: Int { cues.count }
    public var duration: TimeInterval { cues.last?.endTime ?? 0 }
    public var isEmpty: Bool { cues.isEmpty }

    private func parseSRT(_ data: Data) -> [SubtitleCue] {
        guard let string = String(data: data, encoding: .utf8) ??
                          String(data: data, encoding: .isoLatin1) else {
            return []
        }
        return parseSRTString(string)
    }

    private func parseSRTString(_ string: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 3 else { continue }

            guard let sequenceNumber = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }

            let timeLine = lines[1]
            guard let times = parseTimeLine(timeLine) else { continue }

            let text = lines[2...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(
                sequenceNumber: sequenceNumber,
                startTime: times.start,
                endTime: times.end,
                text: text
            ))
        }

        return cues
    }

    private func parseTimeLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let pattern = #"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        func timeComponent(at index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return Int(line[range])
        }

        guard let startH = timeComponent(at: 1),
              let startM = timeComponent(at: 2),
              let startS = timeComponent(at: 3),
              let startMs = timeComponent(at: 4),
              let endH = timeComponent(at: 5),
              let endM = timeComponent(at: 6),
              let endS = timeComponent(at: 7),
              let endMs = timeComponent(at: 8) else {
            return nil
        }

        let start = TimeInterval(startH * 3600 + startM * 60 + startS) + TimeInterval(startMs) / 1000
        let end = TimeInterval(endH * 3600 + endM * 60 + endS) + TimeInterval(endMs) / 1000

        return (start, end)
    }
}
