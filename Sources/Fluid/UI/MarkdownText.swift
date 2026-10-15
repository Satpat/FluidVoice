import SwiftUI

/// Renders LLM-generated markdown (headers, lists, bold/italic, links) the
/// way it would look in a compiled markdown file, instead of showing the
/// raw `**`/`#`/`-` characters as plain text.
struct MarkdownText: View {
    let markdown: String

    private struct Block: Identifiable {
        let id: Int
        let kind: PresentationIntent.Kind?
        let isOrdered: Bool
        let text: AttributedString
    }

    // Parsing markdown into blocks is pure given `markdown`, but SwiftUI
    // re-evaluates `body` (and so re-runs this) on any parent re-render, not
    // just when the text actually changes — expensive to redo per frame for
    // a long summary in a scrolling list. Cache by source string; a handful
    // of distinct summaries/messages on screen at once is normal, so cap
    // the cache instead of growing it unbounded.
    private static var parseCache: [String: [Block]] = [:]
    private static let maxCacheEntries = 32

    private var blocks: [Block] {
        if let cached = Self.parseCache[self.markdown] { return cached }
        let computed = Self.parse(self.markdown)
        if Self.parseCache.count >= Self.maxCacheEntries {
            Self.parseCache.removeAll()
        }
        Self.parseCache[self.markdown] = computed
        return computed
    }

    private static func parse(_ markdown: String) -> [Block] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else {
            return [Block(id: 0, kind: nil, isOrdered: false, text: AttributedString(markdown))]
        }

        var result: [Block] = []
        var currentIdentity: Int?
        var currentText = AttributedString()
        var currentKind: PresentationIntent.Kind?
        var currentOrdered = false

        func flush() {
            guard !currentText.characters.isEmpty else { return }
            result.append(Block(id: result.count, kind: currentKind, isOrdered: currentOrdered, text: currentText))
            currentText = AttributedString()
        }

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            if identity != currentIdentity {
                flush()
                currentIdentity = identity
                currentKind = components.first?.kind
                currentOrdered = components.contains {
                    if case .orderedList = $0.kind { return true }
                    return false
                }
            }
            currentText += attributed[run.range]
        }
        flush()

        return result.isEmpty
            ? [Block(id: 0, kind: nil, isOrdered: false, text: AttributedString(markdown))]
            : result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(self.blocks) { block in
                self.render(block)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font(Self.headerFont(level))
                .fontWeight(.semibold)
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(block.isOrdered ? "\(ordinal)." : "•")
                    .foregroundColor(.secondary)
                Text(block.text)
            }
            .padding(.leading, 8)
        default:
            Text(block.text)
        }
    }

    private static func headerFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }
}
