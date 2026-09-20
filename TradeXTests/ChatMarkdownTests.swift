//
//  ChatMarkdownTests.swift
//  TradeXTests
//

import Foundation
import Testing
@testable import TradeX

struct ChatMarkdownTests {

    /// The plain text a bubble ends up showing, markup resolved.
    private func rendered(_ raw: String) -> String {
        String(ChatMarkdown.attributed(raw).characters)
    }

    @Test("Emphasis is applied rather than printed")
    func boldIsParsed() {
        // The reply that exposed this rendered its own asterisks on screen.
        let text = rendered("Reliance is in the **Energy/Oil-&-Gas** sector")

        #expect(text == "Reliance is in the Energy/Oil-&-Gas sector")
        #expect(!text.contains("**"))
    }

    @Test("Italics and inline code are parsed too")
    func otherInlineSyntax() {
        #expect(rendered("that is *probably* fine") == "that is probably fine")
        #expect(rendered("call `refreshPrices()` first") == "call refreshPrices() first")
    }

    @Test("Line breaks survive, because a reply's shape is part of it")
    func newlinesPreserved() {
        let text = rendered("First line\nSecond line\n\nNew paragraph")

        #expect(text.contains("\n"))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
    }

    @Test("Bullets become bullets instead of stray asterisks")
    func bulletsNormalised() {
        let text = ChatMarkdown.normalisingBlockSyntax("- one\n* two\n+ three")
        let lines = text.split(separator: "\n")

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.hasPrefix("•") })
        #expect(!text.contains("* "))
    }

    @Test("A bulleted list renders without leaking markup")
    func bulletsEndToEnd() {
        let text = rendered("Risks:\n* concentration\n* liquidity")

        #expect(text.contains("•\u{00A0}concentration"))
        #expect(!text.contains("* "))
    }

    @Test("Indentation is kept, so nested points stay nested")
    func indentationPreserved() {
        let text = ChatMarkdown.normalisingBlockSyntax("- top\n    - nested")

        #expect(text.contains("\n    •"))
    }

    @Test("Heading markers are dropped, not displayed")
    func headingsStripped() {
        #expect(ChatMarkdown.normalisingBlockSyntax("### Summary") == "Summary")
        #expect(ChatMarkdown.normalisingBlockSyntax("# A\n## B") == "A\nB")
    }

    @Test("A bare hash is left alone rather than collapsing to nothing")
    func loneHash() {
        #expect(ChatMarkdown.normalisingBlockSyntax("#") == "")
        #expect(rendered("costs # of trades") == "costs # of trades")
    }

    @Test("Ordinary prose passes through untouched")
    func plainTextUnchanged() {
        let plain = "Your portfolio is concentrated in one stock. That is the risk."
        #expect(rendered(plain) == plain)
    }

    @Test("Unbalanced markup still yields a readable message")
    func brokenMarkupDoesNotLoseTheText() {
        let text = rendered("this **never closes")
        #expect(text.contains("never closes"))
    }

    @Test("An empty reply renders as empty rather than crashing")
    func emptyInput() {
        #expect(rendered("") == "")
    }
}
