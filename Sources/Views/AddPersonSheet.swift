import SwiftUI
import SwiftData
import UIKit

// MARK: - Inline add card

/// A natural-language composer that appears inline at the top of the people list.
/// As the user types, significant words are highlighted (name → indigo, address → green,
/// interest keywords → orange) — the same "emojify" underline style iMessage uses.
struct AddPersonInline: View {
    @Environment(\.modelContext) private var context
    var onDone: () -> Void

    @State private var text = ""
    @State private var entities: [DetectedEntity] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Label("New person", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                Button("Cancel") { onDone() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Natural-language input with live entity highlights
            HighlightingTextEditor(text: $text, entities: $entities,
                                   placeholder: "e.g. Maria at 12 Oak St, studying",
                                   autoFocus: true)
                .frame(minHeight: 44, maxHeight: 130)

            // Live entity preview chips — so the user can see what was understood
            if !entities.isEmpty {
                parsedPreview
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Submit
            Button {
                submit()
            } label: {
                Text("Add person")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .controlSize(.regular)
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.18), value: entities.isEmpty)
        .onAppear { focused = true }
    }

    // MARK: Parsed preview

    @ViewBuilder
    private var parsedPreview: some View {
        let parsed = FallbackParser.parse(text)
        HStack(spacing: 8) {
            if !parsed.personName.isEmpty {
                chip(parsed.personName, icon: "person", color: .indigo)
            }
            if !parsed.address.isEmpty {
                chip(parsed.address, icon: "mappin", color: .green)
            }
            if let level = interestFromEntities() {
                chip(level.label, icon: level.symbol, color: interestColor(level))
            }
        }
    }

    private func chip(_ label: String, icon: String, color: Color) -> some View {
        Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(Glass.regular.tint(color), in: Capsule())
            .lineLimit(1)
    }

    private func interestFromEntities() -> InterestLevel? {
        let interestEntity = entities.first { $0.kind == .interest }
        guard let entity = interestEntity else { return nil }
        let kw = String(text[entity.range]).lowercased()
        if kw.contains("stud") { return .studying }
        if kw.contains("interest") || kw.contains("receptive") { return .interested }
        if kw.contains("paus") || kw.contains("stopped") || kw.contains("not") { return .paused }
        return .new
    }

    private func interestColor(_ level: InterestLevel) -> Color {
        switch level {
        case .new: .purple
        case .interested: .green
        case .studying: .blue
        case .paused: .gray
        }
    }

    // MARK: Submit

    private func submit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        let parsed = FallbackParser.parse(raw)

        // Fall back to the full raw text as name if the parser couldn't find one
        let name = parsed.personName.isEmpty ? raw : parsed.personName
        let interest = interestFromEntities() ?? parsed.interest.level ?? .new

        let person = Person(name: name, addressText: parsed.address, interest: interest)
        context.insert(person)

        if !person.addressText.isEmpty {
            let addr = person.addressText
            Task {
                if let coord = await AddressGeocoder.coordinate(for: addr) {
                    person.latitude = coord.latitude
                    person.longitude = coord.longitude
                }
            }
        }

        context.saveIfPossible()
        onDone()
    }
}

// MARK: - Highlighting text editor

/// A `UITextView` wrapper that applies colored underlines to detected entities as the
/// user types — name (indigo), address (green), interest keyword (orange) — matching
/// the iMessage emojify "tap the word" highlight style.
struct HighlightingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var entities: [DetectedEntity]
    var placeholder: String
    /// When true, the underlying UITextView grabs first-responder focus on first appearance.
    var autoFocus: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .yes
        tv.autocapitalizationType = .sentences
        tv.returnKeyType = .default
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Placeholder label — hidden once there's any text
        let placeholder = UILabel()
        placeholder.text = self.placeholder
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.tag = 999
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: tv.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: tv.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: tv.trailingAnchor),
        ])

        // Defer to next run-loop tick so the view is in the window hierarchy first.
        if autoFocus {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        }

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Update placeholder visibility
        if let placeholder = tv.viewWithTag(999) {
            placeholder.isHidden = !text.isEmpty
        }

        // Only reapply attributes when text content actually changed to avoid cursor jumps
        guard tv.text != text || context.coordinator.needsHighlightUpdate else { return }
        context.coordinator.needsHighlightUpdate = false

        // Build the highlighted attributed string
        let attributed = EntityHighlighter.attributedString(for: text)
        let selectedRange = tv.selectedRange

        tv.attributedText = attributed

        // Restore cursor — clamp to the (unchanged) length
        let len = (text as NSString).length
        let safeLocation = min(selectedRange.location, len)
        tv.selectedRange = NSRange(location: safeLocation, length: 0)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingTextEditor
        var needsHighlightUpdate = false

        init(_ parent: HighlightingTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let newText = textView.text ?? ""
            parent.text = newText
            needsHighlightUpdate = true
            parent.entities = EntityHighlighter.detect(in: newText)
        }
    }
}

// MARK: - Entity detection + highlighting

struct DetectedEntity: Equatable {
    enum Kind: Equatable { case name, address, interest }
    let range: Range<String.Index>
    let kind: Kind
}

enum EntityHighlighter {

    // Colour palette — matches PersonCard's interest chips
    static let nameColor    = UIColor.systemIndigo
    static let addressColor = UIColor.systemGreen
    static let interestColor = UIColor.systemOrange

    /// Build an NSAttributedString with entity underlines applied.
    static func attributedString(for text: String) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ]
        let result = NSMutableAttributedString(string: text, attributes: base)

        for entity in detect(in: text) {
            guard let nsRange = nsRange(of: entity.range, in: text) else { continue }
            let color: UIColor
            switch entity.kind {
            case .name:     color = nameColor
            case .address:  color = addressColor
            case .interest: color = interestColor
            }
            result.addAttributes([
                .foregroundColor: color,
                .underlineStyle: (NSUnderlineStyle.thick).rawValue,
                .underlineColor: color.withAlphaComponent(0.5),
            ], range: nsRange)
        }
        return result
    }

    /// Detect all named entities (name, address, interest) in order of specificity
    /// so that addresses and interest keywords always win over name detection.
    static func detect(in text: String) -> [DetectedEntity] {
        guard !text.isEmpty else { return [] }
        var entities: [DetectedEntity] = []

        // 1. Interest keywords (highest priority — very unambiguous)
        let interestPatterns: [(String, Bool)] = [
            ("not interested", true), ("no longer interested", true),
            ("lost interest", true), ("bible study", false),
            ("studying", false), ("study", false),
            ("interested", false), ("receptive", false),
            ("paused", false), ("stopped studying", false),
        ]
        for (pattern, _) in interestPatterns {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: pattern, options: .caseInsensitive, range: search) {
                if !entities.contains(where: { $0.range.overlaps(range) }) {
                    entities.append(DetectedEntity(range: range, kind: .interest))
                }
                guard range.upperBound < text.endIndex else { break }
                search = range.upperBound..<text.endIndex
            }
        }

        // 2. Addresses: digit sequence + (up to 3 words) + street type
        let streetTypes = ["street", "st", "avenue", "ave", "road", "rd",
                           "boulevard", "blvd", "lane", "ln", "drive", "dr",
                           "way", "court", "ct", "place", "pl", "terrace", "circle", "crescent"]
        if let regex = try? NSRegularExpression(
            pattern: #"\b\d+\s+(?:\w+\s+){0,3}(?:"# + streetTypes.joined(separator: "|") + #")\b"#,
            options: .caseInsensitive
        ) {
            let nsText = text as NSString
            let full = NSRange(location: 0, length: nsText.length)
            for match in regex.matches(in: text, range: full) {
                if let range = Range(match.range, in: text),
                   !entities.contains(where: { $0.range.overlaps(range) }) {
                    entities.append(DetectedEntity(range: range, kind: .address))
                }
            }
        }

        // 3. Names: Title Case word(s) not at position 0 and not a common skip word
        //    We look for them after intro phrases ("met", "saw", "for", etc.) or anywhere
        //    mid-sentence where a capitalised word cluster appears.
        let skipWords: Set<String> = [
            "The", "A", "An", "At", "In", "On", "To", "Of", "By", "As",
            "She", "He", "They", "We", "I", "It", "You",
            "Is", "Are", "Was", "Were", "Has", "Have",
            "This", "That", "These", "Those",
            "Her", "His", "Their", "Our", "My", "Your",
            "And", "Or", "But", "So", "For", "If",
            "St", "Ave", "Rd", "Dr", "Ln", "Ct", "Pl",   // street abbreviations
        ]

        // Scan word by word, collecting runs of Title Case non-skip tokens
        let tokenRegex = try? NSRegularExpression(pattern: #"\S+"#)
        let nsText = text as NSString
        var tokenRanges: [(Range<String.Index>, String)] = []
        if let tokenRegex {
            for match in tokenRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                if let range = Range(match.range, in: text) {
                    let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
                    tokenRanges.append((range, word))
                }
            }
        }

        var i = 0
        while i < tokenRanges.count {
            let (range, word) = tokenRanges[i]
            // Skip position 0 (sentence start) unless preceded by an intro trigger
            let isFirstWord = range.lowerBound == text.startIndex
            let isCapitalized = word.first?.isUppercase == true && !word.allSatisfy(\.isUppercase)
            let isSkip = skipWords.contains(word)
            let alreadyCovered = entities.contains { $0.range.overlaps(range) }

            if isCapitalized && !isSkip && !isFirstWord && !alreadyCovered {
                // Extend the run to cover consecutive Title Case words (multi-word names)
                var runEnd = range.upperBound
                var j = i + 1
                while j < tokenRanges.count {
                    let (nextRange, nextWord) = tokenRanges[j]
                    let nextClean = nextWord.trimmingCharacters(in: .punctuationCharacters)
                    if nextClean.first?.isUppercase == true && !skipWords.contains(nextClean)
                       && !entities.contains(where: { $0.range.overlaps(nextRange) }) {
                        runEnd = nextRange.upperBound
                        j += 1
                    } else { break }
                }
                let nameRange = range.lowerBound..<runEnd
                if !entities.contains(where: { $0.range.overlaps(nameRange) }) {
                    entities.append(DetectedEntity(range: nameRange, kind: .name))
                }
                i = j
                continue
            }
            i += 1
        }

        return entities
    }

    private static func nsRange(of range: Range<String.Index>, in text: String) -> NSRange? {
        NSRange(range, in: text)
    }
}
