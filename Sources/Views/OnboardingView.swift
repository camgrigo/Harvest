import SwiftUI

/// A short first-run welcome explaining how the notebook works and that it stays private.
struct OnboardingView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: "book.closed.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.bottom, 12)

            Text("Your return-visit notebook")
                .font(.largeTitle.bold())
            Text("Keep track of the people you call back on — without the busywork.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 18) {
                point("text.bubble.fill", "Just tell the notebook",
                      "Write what happened in your own words. It files the person, the note, and a reminder for you.")
                point("sparkles", "Ask for a summary",
                      "You don't have to re-read anything — ask “Summarize Maria” or “Catch me up on this week.”")
                point("map.fill", "See them on the map",
                      "Anyone with an address shows up as a pin, with directions a tap away.")
                point("lock.fill", "Stays on your iPhone",
                      "Everything runs on-device. Names, addresses, and notes never leave your phone.")
            }
            .padding(.top, 28)

            Spacer()

            Button(action: onDone) {
                Text("Start my notebook")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
    }

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
        }
    }
}
