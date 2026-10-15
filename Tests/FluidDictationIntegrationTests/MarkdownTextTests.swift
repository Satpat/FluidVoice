@testable import FluidVoice_Debug
import SwiftUI
import XCTest

// MarkdownText.parse turns LLM summaries into renderable blocks. Regression
// coverage for list items, which used to come out as plain paragraphs because
// the block kind was read from the innermost (paragraph) component.

@MainActor
final class MarkdownTextTests: XCTestCase {
    private func describe(_ block: MarkdownText.Block) -> String {
        let text = String(block.text.characters)
        switch block.kind {
        case .header(let level): return "h\(level):\(text)"
        case .listItem(let ordinal):
            return "\(block.isOrdered ? "ol\(ordinal)" : "ul")@\(block.depth):\(text)"
        default: return "p@\(block.depth):\(text)"
        }
    }

    func testUnorderedListItemsAreListBlocks() {
        let blocks = MarkdownText.parse("- first\n- second").map(self.describe)
        XCTAssertEqual(blocks, ["ul@1:first", "ul@1:second"])
    }

    func testOrderedListKeepsOrdinals() {
        let blocks = MarkdownText.parse("1. alpha\n2. beta").map(self.describe)
        XCTAssertEqual(blocks, ["ol1@1:alpha", "ol2@1:beta"])
    }

    func testNestedListReportsDepth() {
        let markdown = """
        - Topic discussed
          - What was discussed
        - Second topic
        """
        let blocks = MarkdownText.parse(markdown).map(self.describe)
        XCTAssertEqual(blocks, ["ul@1:Topic discussed", "ul@2:What was discussed", "ul@1:Second topic"])
    }

    func testHeadersAndParagraphs() {
        let markdown = """
        ## Overview
        A short meeting about **releases**.
        """
        let blocks = MarkdownText.parse(markdown).map(self.describe)
        XCTAssertEqual(blocks, ["h2:Overview", "p@0:A short meeting about releases."])
    }

    func testBoldInsideListItemStaysOneBlock() {
        let blocks = MarkdownText.parse("- **What**: ship it").map(self.describe)
        XCTAssertEqual(blocks, ["ul@1:What: ship it"])
    }
}
