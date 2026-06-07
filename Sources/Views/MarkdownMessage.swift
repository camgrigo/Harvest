import SwiftUI

/// Renders an assistant message as lightweight markdown — headings, bullet lists, and inline
/// **bold**/_italic_/`code` — so summaries and weekly briefings read like a proper answer rather
/// than raw text. Inline styling uses AttributedString; block structure is handled here.
struct MarkdownMessage: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(inline(content))
                .font(level <= 1 ? .title3.bold() : .headline)
                .padding(.top, 2)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(content)).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let content):
            Text(inline(content)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Parsing

    private enum Block {
        case heading(level: Int, String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") { return .heading(level: 3, String(line.dropFirst(4))) }
            if line.hasPrefix("## ")  { return .heading(level: 2, String(line.dropFirst(3))) }
            if line.hasPrefix("# ")   { return .heading(level: 1, String(line.dropFirst(2))) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return .bullet(String(line.dropFirst(2)))
            }
            return .paragraph(line)
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }
}
