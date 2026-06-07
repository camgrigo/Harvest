# Harvest

A chatbot‑first iOS app for Jehovah's Witnesses' field ministry — keep track of the people you
call back on **and** the territories you work, all on one map, all on your phone.

Write what happened in your own words and the notebook files the person, the note, and a reminder
for you. Walk a territory and log not‑at‑homes in a tap. Everything runs **on‑device** — names,
addresses, and notes never leave the phone.

> The Xcode scheme/product is `ReturnVisitNotebook`; the app installs as **Harvest**.

---

## Features

### One map, two kinds of work
A full‑bleed map (Find My style) with a floating bottom sheet that lists **People** (return visits)
and **Territories** (house‑to‑house areas) in one feed. Tap a pin or a card to open it; search,
sort (recent / nearest / due / name), and a show/hide‑territories toggle live inline.

### Return visits (people)
- **Just tell it what happened** — natural‑language notes are parsed into the person, address,
  interest, and a smart follow‑up reminder.
- **Ask for a recap** — on‑device summaries ("Summarize Maria", "Catch me up on this week").
- **Edit by asking** — "change Maria's interest to studying", "push her to Friday", "clear her reminder".
- Look Around header, **set the address by dropping a pin on a map**, interest/status, sharing, and
  **soft‑deleted notes** with a 30‑day *Recently Deleted* recovery.

### Territories (house‑to‑house)
- **Scan a territory card** with the camera — on‑device OCR reads the **do‑not‑call** list.
- Log **not‑at‑homes** as you walk: "Add nearest address", or type an address with **live nearby
  search**; duplicates are de‑duped (a repeat knock just bumps the count, or undo a try).
- **Best‑time‑to‑return hints** — each door learns from when you've tried it ("Always tried
  mornings — try evening").
- **"Someone answered" → promote** a door into a return visit, carrying its address, pin, and
  attempt history into the new person's first note.
- Walking **Directions**, an attached **link** or **photo**, and **sharing**.

### Private by design
- 100% on‑device. The AI is **Apple Intelligence** (the on‑device model), with a deterministic
  offline fallback when it's unavailable — so the app works everywhere.
- It recognises **jw.org publications** and abbreviations (e.g. *ELF* = *Enjoy Life Forever!*) and
  never invents non‑jw.org titles.
- **Encrypted backup & restore** — export your whole notebook as one passphrase‑encrypted file
  (AES‑GCM, key derived via HKDF‑SHA256) and share it however you like. It's useless without the
  passphrase, and only leaves the device if you choose to share it.

---

## Tech

- **iOS 26**, **SwiftUI**, **SwiftData**, Swift 6 (strict concurrency)
- **FoundationModels** — on‑device LLM for parsing + summaries
- **MapKit** — map, Look Around stills, geocoding, local search
- **Vision** — territory‑card OCR
- **Speech** — voice dictation of notes
- **CryptoKit** — backup encryption
- **XcodeGen** — the `.xcodeproj` is generated from `project.yml`
- **XCTest** — unit tests for the parser, hints, promotion, and migrations

The UI uses the iOS 26 **glass** design (`.glassEffect`), a custom wheat app icon, and a custom
"territory" symbol — both generated procedurally with Core Graphics.

---

## Building

Requires **Xcode 26** (iOS 26 SDK) and a device or simulator running iOS 26.

```sh
# 1. Generate the Xcode project from project.yml
brew install xcodegen        # if you don't have it
xcodegen generate

# 2. Open and run
open ReturnVisitNotebook.xcodeproj
#    …or build from the command line:
xcodebuild -scheme ReturnVisitNotebook \
  -destination 'platform=iOS,name=Your iPhone' -configuration Debug build
```

Run `xcodegen generate` again whenever Swift files are added or removed.

### Tests

```sh
xcodebuild test -scheme ReturnVisitNotebook \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ReturnVisitNotebookTests
```

---

## Project layout

```
Sources/
  App.swift                 # @main, ModelContainer
  Models/                   # Person, JournalEntry, Territory, NotAtHome, DoNotCall,
                            #   ChatMessage, InterestLevel, ReturnHint
  Views/                    # RootView, ExploreView + ExplorePanel, FeedCards,
                            #   PersonDetailView, TerritoryDetailView, ScanTerritoryView,
                            #   ConversationView (chat), SettingsView (backup), …
  Services/                 # Geocoder, NearbyAddresses, TextRecognizer (OCR),
                            #   NotAtHomePromotion, BackupService, ReminderScheduler, …
  AI/                       # Assistant (FoundationModels), FallbackParser,
                            #   NotebookEngine, ChatAction, ChatThread
  Assets.xcassets/          # App icon + custom "Territory" symbol
Tests/                      # XCTest unit tests
UITests/                    # XCUITest
project.yml                 # XcodeGen project definition
ROADMAP.md                  # ideas for what's next
```

---

## Privacy

Harvest holds real people's details, so it's built to keep them private: the data lives only in
the app's on‑device store, the language model runs locally, and the only way data leaves the phone
is an encrypted backup **you** choose to share. There is no account, no analytics, and no network
sync.

---

*Built with [Claude Code](https://claude.com/claude-code).*
