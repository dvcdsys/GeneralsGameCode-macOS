import SwiftUI
import AppKit

/// Renders markdown as styled, scrollable, selectable text using AppKit's
/// `NSAttributedString(markdown:)` (block-level, macOS 12+) in an `NSTextView`.
/// No third-party dependencies. Headings/code blocks/inline code are styled by
/// post-processing the parsed presentation intents.
struct MarkdownView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 16, height: 16)
            tv.textContainer?.widthTracksTextView = true
            tv.isAutomaticLinkDetectionEnabled = true
            tv.linkTextAttributes = [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textStorage?.setAttributedString(Self.render(markdown))
        tv.scroll(.zero)
    }

    // MARK: - rendering

    static func render(_ md: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 13)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)

        guard let immutable = try? NSAttributedString(
            markdown: md, options: options, baseURL: nil) else {
            return NSAttributedString(string: md,
                attributes: [.font: base, .foregroundColor: NSColor.labelColor])
        }
        let parsed = NSMutableAttributedString(attributedString: immutable)
        let full = NSRange(location: 0, length: parsed.length)

        parsed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        parsed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            if value == nil { parsed.addAttribute(.font, value: base, range: range) }
        }

        // Block-level intents: headers, code blocks.
        parsed.enumerateAttribute(.presentationIntentAttributeName, in: full, options: []) { value, range, _ in
            guard let intent = value as? PresentationIntent else { return }
            for comp in intent.components {
                switch comp.kind {
                case .header(let level):
                    let size: CGFloat = level <= 1 ? 22 : level == 2 ? 18 : level == 3 ? 15 : 13
                    parsed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range)
                case .codeBlock:
                    parsed.addAttribute(.font, value: mono, range: range)
                    parsed.addAttribute(.backgroundColor,
                        value: NSColor.textBackgroundColor.withAlphaComponent(0.5), range: range)
                default:
                    break
                }
            }
        }

        // Inline intents: code, strong, emphasis.
        parsed.enumerateAttribute(.inlinePresentationIntent, in: full, options: []) { value, range, _ in
            let intent: InlinePresentationIntent
            if let i = value as? InlinePresentationIntent { intent = i }
            else if let n = value as? NSNumber { intent = InlinePresentationIntent(rawValue: n.uintValue) }
            else { return }

            if intent.contains(.code) {
                parsed.addAttribute(.font, value: mono, range: range)
            }
            if intent.contains(.stronglyEmphasized) {
                parsed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: range)
            }
            if intent.contains(.emphasized) {
                let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                parsed.addAttribute(.font, value: italic, range: range)
            }
        }

        return parsed
    }
}
