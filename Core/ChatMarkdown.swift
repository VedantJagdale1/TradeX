//
//  ChatMarkdown.swift
//  TradeX
//

import Foundation

/// Renders the markdown a language model emits into something readable.
///
/// SwiftUI parses markdown only in `Text` built from a literal `LocalizedStringKey`;
/// a `String` held at runtime is drawn exactly as it arrives, which is why model
/// replies were showing their own asterisks — "**Energy/Oil-&-Gas**" on screen, markup
/// and all.
///
/// Pure string work with no view state, so it is `nonisolated` — the project defaults
/// every type to the main actor, which otherwise makes it unusable from a background
/// context and warns at its own call sites.
nonisolated enum ChatMarkdown {

    /// Parses inline markup while keeping the line breaks the model wrote.
    ///
    /// Full-document parsing would be wrong here: it collapses newlines into
    /// paragraphs and discards the line structure a chat reply depends on. Block
    /// syntax that the inline parser ignores is normalised first, so a heading or a
    /// bullet reads as one rather than leaving its markers on screen.
    static func attributed(_ raw: String) -> AttributedString {
        let cleaned = normalisingBlockSyntax(raw)

        guard let parsed = try? AttributedString(
            markdown: cleaned,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            // Unparseable markup is still a message worth showing.
            return AttributedString(cleaned)
        }

        return parsed
    }

    /// Turns block markers the inline parser leaves alone into plain typography.
    static func normalisingBlockSyntax(_ raw: String) -> String {
        raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(normalisingLine)
            .joined(separator: "\n")
    }

    private static func normalisingLine(_ line: Substring) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(indent.count)

        // A heading's hashes carry no meaning once the text is not a document.
        if body.hasPrefix("#") {
            let text = body.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? String(indent) : indent + text
        }

        // A leading "* " is a bullet, not the start of emphasis — the inline parser
        // reads it as an unterminated italic and leaves the asterisk in place.
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            return indent + "•\u{00A0}" + body.dropFirst(marker.count)
        }

        return String(line)
    }
}
