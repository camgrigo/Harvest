import SwiftUI
import SwiftData
import UIKit

/// The general notebook conversation (the Notebook tab). Just a `ConversationView` with no person
/// scope, wrapped in its own navigation stack.
struct ChatView: View {
    var body: some View {
        NavigationStack {
            ConversationView(person: nil)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A chat transcript + composer. With `person == nil` it's the general notebook; with a person it's
/// that person's own thread, and everything you say is filed against them automatically. Replies
/// stream in and render as markdown; the overflow menu can clear the conversation (kept, not
/// deleted) and reveal cleared history.
struct ConversationView: View {
    let person: Person?
    /// When true, the composer grabs focus on appear (used when arriving from the
    /// tap-to-chat box so it feels like tapping an iMessage field).
    var autofocusInput = false

    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.date) private var allMessages: [ChatMessage]
    @Query private var people: [Person]

    @Environment(\.openURL) private var openURL
    @State private var assistant = Assistant()
    @StateObject private var dictation = SpeechTranscriber()
    @State private var draft = ""
    @State private var isThinking = false
    @State private var showCleared = false
    @FocusState private var inputFocused: Bool

    // Streaming + generation control.
    @State private var streamingID: PersistentIdentifier?
    @State private var revealed = ""
    @State private var genTask: Task<Void, Never>?
    @State private var atBottom = true

    private var messages: [ChatMessage] {
        ChatThread.messages(in: allMessages, person: person, includeCleared: showCleared)
    }
    private var activeCount: Int {
        ChatThread.messages(in: allMessages, person: person).count
    }
    private var hasCleared: Bool {
        ChatThread.hasCleared(in: allMessages, person: person)
    }
    private var isGenerating: Bool { isThinking || streamingID != nil }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = Assistant.unavailabilityReason {
                fallbackBanner(reason)
            }
            transcript
            composer
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .task {
            // Let the push animation settle before raising the keyboard.
            guard autofocusInput else { return }
            try? await Task.sleep(for: .milliseconds(350))
            inputFocused = true
        }
    }

    // MARK: Menu

    private var menu: some View {
        Menu {
            Button(role: .destructive) {
                clearConversation()
            } label: {
                Label("Clear conversation", systemImage: "eraser")
            }
            .disabled(activeCount == 0)

            if hasCleared {
                Toggle(isOn: $showCleared) {
                    Label("Show cleared", systemImage: "clock.arrow.circlepath")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Conversation options")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty { welcome }
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            streamedText: message.persistentModelID == streamingID ? revealed : nil,
                            canRegenerate: isRegenerable(message),
                            onCopy: { copy(message) },
                            onRegenerate: { regenerate(message) }
                        )
                        .id(message.id)
                    }
                    if isThinking {
                        thinkingRow.id("thinking")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y >= geo.contentSize.height - geo.bounds.height - 60
            } action: { _, newValue in
                atBottom = newValue
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !messages.isEmpty {
                    Button {
                        scrollToEnd(proxy)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .onChange(of: messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: revealed) { _, _ in if atBottom { scrollToEnd(proxy) } }
            .onChange(of: isThinking) { _, _ in scrollToEnd(proxy) }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            assistantGlyph
            ProgressView()
            Text("Thinking…").foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(person == nil ? "Your return-visit notebook" : "Chat about \(person!.name)")
                .font(.title2.weight(.semibold))
            Text(person == nil
                 ? "Just write what happened in your own words and I'll keep track. Tap a starter to fill in, or type your own:"
                 : "Tell me how it went and I'll file it on \(person!.name)'s page. Tap a starter to fill in, or type your own:")
                .foregroundStyle(.secondary)
            ForEach(samplePrompts, id: \.self) { example in
                Button {
                    draft = example
                    inputFocused = true
                } label: {
                    Text(example)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16)
    }

    private var activePeople: [Person] { people.filter { !$0.isArchived } }

    private var hasDuePeople: Bool {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now)!
        return activePeople.contains { ($0.nextVisitDate ?? .distantFuture) <= horizon }
    }

    /// Generic fill-in starters (no fake data) plus query prompts that only appear once there's
    /// actually something to act on.
    private var samplePrompts: [String] {
        if let person {
            var prompts = [
                "Talked about … — go back …",
                "Lives at …",
                "Mark as studying"
            ]
            if !person.sortedEntries.isEmpty { prompts.append("Summarize where things stand") }
            return prompts
        }

        var prompts = [
            "Met someone today — here's who, where, and what we talked about …",
            "Set a reminder to go back to …",
            "Add an address for …"
        ]
        if !activePeople.isEmpty { prompts.append("Who should I see this week?") }
        if hasDuePeople { prompts.append("Catch me up on everyone due this week") }
        return prompts
    }

    private var assistantGlyph: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.tint)
            .frame(width: 26, height: 26)
            .background(Color(.secondarySystemBackground), in: Circle())
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if dictation.isSupported {
                Button {
                    Task { await dictation.toggle() }
                } label: {
                    Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 24))
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                        .frame(width: 32, height: 38)
                }
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate a note")
            }
            TextField(dictation.isRecording ? "Listening…" : "Note…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20))
                .onChange(of: draft) { _, newValue in
                    // Return key inserts a newline in a vertical field — treat it as "send".
                    if newValue.hasSuffix("\n") {
                        draft = String(newValue.dropLast())
                        startSend()
                    }
                }
                .onChange(of: dictation.transcript) { _, text in
                    if dictation.isRecording { draft = text }
                }
            sendOrStopButton
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isGenerating {
            Button {
                genTask?.cancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Stop")
        } else {
            Button {
                startSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func fallbackBanner(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if Assistant.unavailabilityActionable {
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: Actions

    private func startSend() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        draft = ""
        dictation.reset()
        genTask = Task {
            await performSend(text)
            genTask = nil
        }
    }

    private func performSend(_ text: String) async {
        record(text, fromUser: true)
        isThinking = true

        var parsed = await assistant.parse(text)
        if Task.isCancelled { isThinking = false; return }
        if let person { parsed.personName = person.name }
        let reply = await NotebookEngine.apply(parsed, original: text, assistant: assistant, context: context)

        isThinking = false
        let bot = record(reply, fromUser: false)
        await reveal(bot)
    }

    /// Word-by-word reveal of a finished reply, so it streams in like a live answer. Cancelling
    /// (Stop) jumps straight to the full text.
    private func reveal(_ message: ChatMessage) async {
        let full = message.text
        streamingID = message.persistentModelID
        revealed = ""
        defer { streamingID = nil; revealed = "" }

        var accumulated = ""
        for (index, word) in full.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if Task.isCancelled { break }
            accumulated += (index == 0 ? "" : " ") + word
            revealed = accumulated
            try? await Task.sleep(for: .milliseconds(26))
        }
    }

    private func copy(_ message: ChatMessage) {
        UIPasteboard.general.string = message.text
    }

    /// True only for the latest assistant reply whose prompt was a read-only query — re-running a
    /// note/edit would duplicate side effects, so we don't offer it there.
    private func isRegenerable(_ message: ChatMessage) -> Bool {
        guard !message.isFromUser, !isGenerating else { return false }
        let thread = ChatThread.messages(in: allMessages, person: person)
        guard let index = thread.firstIndex(where: { $0.id == message.id }),
              index == thread.count - 1, index > 0 else { return false }
        let prompt = thread[index - 1]
        guard prompt.isFromUser else { return false }
        switch FallbackParser.parse(prompt.text).intent {
        case .summarizePerson, .listDue, .summarizeDue: return true
        default: return false
        }
    }

    private func regenerate(_ message: ChatMessage) {
        let thread = ChatThread.messages(in: allMessages, person: person)
        guard let index = thread.firstIndex(where: { $0.id == message.id }), index > 0 else { return }
        let prompt = thread[index - 1]
        guard prompt.isFromUser else { return }
        genTask = Task {
            isThinking = true
            var parsed = await assistant.parse(prompt.text)
            if let person { parsed.personName = person.name }
            // Only re-run read-only intents so we never duplicate filed notes.
            switch parsed.intent {
            case .summarizePerson, .listDue, .summarizeDue:
                let reply = await NotebookEngine.apply(parsed, original: prompt.text,
                                                       assistant: assistant, context: context)
                message.text = reply
                context.saveIfPossible()
                isThinking = false
                await reveal(message)
            default:
                isThinking = false
            }
            genTask = nil
        }
    }

    /// Inserts a chat line on this thread and persists it, recovering (and retrying once) if the
    /// context was left in a bad state by an earlier failed save. Returns the saved message.
    @discardableResult
    private func record(_ text: String, fromUser: Bool) -> ChatMessage {
        let message = ChatMessage(text: text, isFromUser: fromUser, person: person)
        context.insert(message)
        if !context.saveIfPossible() {
            let retry = ChatMessage(text: text, isFromUser: fromUser, person: person)
            context.insert(retry)
            context.saveIfPossible()
            return retry
        }
        return message
    }

    private func clearConversation() {
        ChatThread.clear(allMessages, person: person)
        showCleared = false
        context.saveIfPossible()
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// One row in the transcript: the user on the right in a small bubble, the assistant full-width
/// (document style) with a glyph, markdown rendering, and copy/regenerate actions.
private struct MessageRow: View {
    let message: ChatMessage
    /// Non-nil while this assistant message is streaming in; shows the partial text.
    let streamedText: String?
    let canRegenerate: Bool
    let onCopy: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        if message.isFromUser {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("userMessage")
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(Color(.secondarySystemBackground), in: Circle())
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("botMessage")
                Spacer(minLength: 0)
            }
            .contextMenu {
                Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                if canRegenerate {
                    Button { onRegenerate() } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let streamedText {
            Text("\(streamedText)\(Text(" ▍").foregroundStyle(.secondary))")
                .textSelection(.enabled)
        } else {
            MarkdownMessage(text: message.text)
                .textSelection(.enabled)
        }
    }
}
