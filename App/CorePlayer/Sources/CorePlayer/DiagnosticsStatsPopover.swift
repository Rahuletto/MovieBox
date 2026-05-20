import AppKit
import SwiftUI

public struct DiagnosticsPanelSnapshot: Sendable {
    public struct Row: Identifiable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let value: String

        public init(label: String, value: String) {
            self.id = label
            self.label = label
            self.value = value
        }
    }

    public struct Section: Identifiable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let rows: [Row]

        public init(title: String, rows: [Row]) {
            self.id = title
            self.title = title
            self.rows = rows
        }
    }

    public let title: String
    public let subtitle: String?
    public let capturedAt: Date
    public let sections: [Section]
    public let emptyTitle: String
    public let emptyDescription: String
    public let emptySystemImage: String

    public init(
        title: String,
        subtitle: String? = nil,
        capturedAt: Date = .now,
        sections: [Section],
        emptyTitle: String = "No data",
        emptyDescription: String = "Stats are not available yet.",
        emptySystemImage: String = "gauge.with.dots.needle.67percent"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.capturedAt = capturedAt
        self.sections = sections
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.emptySystemImage = emptySystemImage
    }

    public var clipboardText: String {
        var lines = [
            title,
            "Captured: \(Self.timestampFormatter.string(from: capturedAt))",
        ]
        if let subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        lines.append("")

        if sections.isEmpty {
            lines.append("\(emptyTitle) — \(emptyDescription)")
        } else {
            for section in sections {
                lines.append(section.title.uppercased())
                for row in section.rows {
                    lines.append("  \(row.label): \(row.value)")
                }
                lines.append("")
            }
        }

        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public static let empty = DiagnosticsPanelSnapshot(
        title: "Stats",
        sections: []
    )
}

public struct DiagnosticsStatsPopover: View {
    let snapshot: DiagnosticsPanelSnapshot
    @State private var didCopy = false

    public init(snapshot: DiagnosticsPanelSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.headline)
                    if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button {
                    copySnapshotToPasteboard()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Copy all stats to clipboard")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if snapshot.sections.isEmpty {
                        ContentUnavailableView(
                            snapshot.emptyTitle,
                            systemImage: snapshot.emptySystemImage,
                            description: Text(snapshot.emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(snapshot.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 0) {
                                    ForEach(section.rows) { row in
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text(row.label)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 148, alignment: .leading)
                                            Text(row.value)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 5)
                                        if row.id != section.rows.last?.id {
                                            Divider().opacity(0.35)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 520)
    }

    private func copySnapshotToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.clipboardText, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
