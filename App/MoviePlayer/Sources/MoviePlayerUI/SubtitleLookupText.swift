import AppKit
import SwiftUI

/// Selectable subtitle text for native macOS Look Up (force-click / three-finger tap).
struct SubtitleLookupText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let maxWidth: CGFloat

    func makeNSView(context: Context) -> SubtitleLookupTextView {
        let textView = SubtitleLookupTextView()
        textView.configure(maxWidth: maxWidth)
        textView.apply(text: text, font: font, textColor: textColor, lineSpacing: lineSpacing)
        return textView
    }

    func updateNSView(_ textView: SubtitleLookupTextView, context: Context) {
        textView.configure(maxWidth: maxWidth)
        textView.apply(text: text, font: font, textColor: textColor, lineSpacing: lineSpacing)
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SubtitleLookupTextView, context: Context) -> CGSize? {
        _ = proposal
        return nsView.measuredSize()
    }
}

final class SubtitleLookupTextView: NSTextView {
    private var appliedFont: NSFont = .systemFont(ofSize: 20)
    private var appliedLineSpacing: CGFloat = 0
    private var appliedText: String = ""
    var maxLayoutWidth: CGFloat = 720

    convenience init() {
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        self.init(frame: .zero, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolvedContainer: NSTextContainer
        if let container {
            resolvedContainer = container
        } else {
            let created = NSTextContainer()
            created.lineFragmentPadding = 0
            created.widthTracksTextView = false
            resolvedContainer = created
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        drawsBackground = false
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        isRichText = false
        allowsUndo = false
        insertionPointColor = .clear
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }

    func configure(maxWidth: CGFloat) {
        maxLayoutWidth = maxWidth
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func layout() {
        super.layout()
        relayoutText()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let layoutManager, let textContainer else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: local,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard layoutManager.isValidGlyphIndex(glyphIndex) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < (string as NSString).length else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        return glyphRect.insetBy(dx: -2, dy: -2).contains(local) ? self : nil
    }

    func apply(text: String, font: NSFont, textColor: NSColor, lineSpacing: CGFloat) {
        appliedFont = font
        appliedLineSpacing = lineSpacing
        appliedText = text

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))

        selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.22),
            .foregroundColor: textColor,
        ]

        relayoutText()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func measuredSize() -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = appliedLineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: appliedFont,
            .paragraphStyle: paragraph,
        ]
        let constraint = maxLayoutWidth
        let rect = (appliedText as NSString).boundingRect(
            with: NSSize(width: constraint, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return CGSize(
            width: max(1, min(constraint, ceil(rect.width))),
            height: max(1, ceil(rect.height))
        )
    }

    override var intrinsicContentSize: NSSize {
        let measured = measuredSize()
        return NSSize(width: measured.width, height: measured.height)
    }

    private func relayoutText() {
        guard let container = textContainer, let manager = layoutManager else { return }
        let textWidth = measuredSize().width
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
    }
}
