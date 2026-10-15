import SwiftUI

/// Renders LLM-generated markdown (headers, lists, bold/italic, links) the
/// way it would look in a compiled markdown file, instead of showing the
/// raw `**`/`#`/`-` characters as plain text.
struct MarkdownText: View {
    let markdown: String

    struct Block: Identifiable {
        let id: Int
        let kind: PresentationIntent.Kind?
        let isOrdered: Bool
        /// Number of enclosing lists: 0 for top-level text, 1 for a
        /// top-level list item, 2 for a nested sub-bullet, ...
        let depth: Int
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

    static func parse(_ markdown: String) -> [Block] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else {
            return [Block(id: 0, kind: nil, isOrdered: false, depth: 0, text: AttributedString(markdown))]
        }

        var result: [Block] = []
        var currentIdentity: Int?
        var currentText = AttributedString()
        var currentKind: PresentationIntent.Kind?
        var currentOrdered = false
        var currentDepth = 0

        func flush() {
            guard !currentText.characters.isEmpty else { return }
            result.append(Block(
                id: result.count,
                kind: currentKind,
                isOrdered: currentOrdered,
                depth: currentDepth,
                text: currentText
            ))
            currentText = AttributedString()
        }

        for run in attributed.runs {
            // Components are ordered innermost-first: a bullet's text run is
            // [paragraph, listItem, unorderedList, (listItem, list, ...)]. The
            // innermost component identifies the block; the first header or
            // list item gives its kind, and the list right after that item
            // says whether it is ordered.
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            if identity != currentIdentity {
                flush()
                currentIdentity = identity
                let kindIndex = components.firstIndex { component in
                    switch component.kind {
                    case .header, .listItem: return true
                    default: return false
                    }
                }
                currentKind = kindIndex.map { components[$0].kind } ?? components.first?.kind
                currentOrdered = false
                if let kindIndex, kindIndex + 1 < components.count,
                   case .orderedList = components[kindIndex + 1].kind {
                    currentOrdered = true
                }
                currentDepth = components.filter { component in
                    switch component.kind {
                    case .orderedList, .unorderedList: return true
                    default: return false
                    }
                }.count
            }
            currentText += attributed[run.range]
        }
        flush()

        return result.isEmpty
            ? [Block(id: 0, kind: nil, isOrdered: false, depth: 0, text: AttributedString(markdown))]
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
                Text(block.isOrdered ? "\(ordinal)." : (block.depth > 1 ? "◦" : "•"))
                    .foregroundColor(.secondary)
                Text(block.text)
            }
            .padding(.leading, CGFloat(8 + 16 * max(0, block.depth - 1)))
        default:
            Text(block.text)
                .padding(.leading, CGFloat(16 * block.depth))
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
