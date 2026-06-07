# Return Visits — Feature Roadmap

Ideas for where the app can go next. Everything here respects the founding constraints:
**100% on-device** (names, addresses, and interest never leave the iPhone), **chat-first**, and
**notebook-simple** (no fiddly forms). Grouped by theme, with a rough effort/value read so you can
pick what's worth doing.

Legend — Effort: 🟢 small · 🟡 medium · 🔴 large. Value: ⭐ nice · ⭐⭐ strong · ⭐⭐⭐ core.

---

## 1. Smarter conversation
- **🟢 ⭐⭐ Conversational reminder edits** — "push Maria to next Tuesday", "remind me sooner".
  The `editPerson` intent already exists; extend it to reschedule/snooze by voice.
- **🟢 ⭐⭐ Undo last action** — "undo" / "that wasn't right" reverts the last filed note or change.
  Cheap insurance against a misparse.
- **🟡 ⭐⭐⭐ Multi-turn follow-ups** — when a note is ambiguous ("saw her again"), the bot asks
  *who?* and remembers the answer instead of guessing. Needs a small pending-question state.
- **🟡 ⭐⭐ Scripture & publication capture** — detect a cited scripture ("John 5:28, 29") or a
  publication/video shared, and keep it as structured fields for richer recaps. jw.org guidance
  leans on "leave something for next time."
- **🟡 ⭐⭐ Topic threading** — group a person's notes by topic ("suffering", "the resurrection")
  so a recap can say "you've covered X, a natural next step is Y."

## 2. Reminders & follow-through
- **🟢 ⭐⭐⭐ Notification actions** — "Mark visited" / "Snooze 3 days" buttons right on the reminder,
  so you act without opening the app.
- **🟢 ⭐⭐ "Visited" quick-confirm** — logging a visit auto-asks whether to set the next one,
  keeping the cadence going while interest is fresh.
- **🟡 ⭐⭐ Time-of-day & day-of-week smarts** — suggest return times based on when you actually
  found people home (all inferred on-device from your own history).
- **🟡 ⭐ Recurring study slots** — once someone reaches "studying", offer a weekly repeating reminder.

## 3. Map & location
- **🟢 ⭐⭐ "Near me now" / route mode** — surface due people close to your current location, or
  order today's list into a sensible walking route.
- **🟢 ⭐⭐ Territory / cluster view** — color or cluster pins by interest level or due status.
- **🟡 ⭐ Geofenced nudges** — a gentle "you're near Maria's — she's due" when you pass by
  (opt-in, on-device region monitoring).
- **🟡 ⭐ Apartment/unit support** — multiple people at one building without overlapping pins.

## 4. Summaries & prep
- **🟢 ⭐⭐⭐ Pre-visit briefing card** — tap a due person to get a one-screen "last time / their
  questions / suggested next step" before you knock.
- **🟡 ⭐⭐ Weekly digest** — a Sunday summary: who you saw, who's slipping, who to prioritize.
- **🟡 ⭐ Talking-point suggestions** — from the notes, propose a next topic or a relevant
  scripture/publication (model stays on-device).

## 5. Capture speed
- **🟢 ⭐⭐⭐ Voice dictation entry** — speak the note in the car after a visit; Speech framework
  on-device, no typing.
- **🟢 ⭐⭐ Home-screen / lock-screen widget** — "who's due today" at a glance; tap to open chat.
- **🟡 ⭐⭐ Siri / App Shortcuts** — "Hey Siri, log a return visit" and "who should I see today?"
- **🟡 ⭐ Share-sheet capture** — drop an address from Maps/Contacts straight into a new person.

## 6. Organization & trust
- **🟢 ⭐⭐ Archive & restore flow** — a visible "no longer interested / moved" state with an easy
  bring-back, instead of just swipe-to-archive.
- **🟢 ⭐⭐⭐ Encrypted backup & restore** — export an encrypted file (or private iCloud sync) so a
  lost phone doesn't mean a lost book. Must stay end-to-end private.
- **🟡 ⭐ Face ID / passcode lock** — gate the app since it holds people's details.
- **🟡 ⭐ Interest history timeline** — see how someone progressed (new → interested → studying).

## 7. Accessibility & polish
- **🟢 ⭐⭐ Dynamic Type & VoiceOver pass** — make sure the chat and map are fully usable.
- **🟢 ⭐ Dark-mode tuning & app-icon variants** — tinted/dark icon options.
- **🟢 ⭐ Empty-state onboarding tips** — sample phrasings surfaced contextually the first week.

---

## Suggested next two
If it were me, I'd do these first — each is small and high-value:
1. **Notification actions ("Mark visited" / "Snooze")** — closes the loop on the core reminder job.
2. **Voice dictation entry** — removes the biggest friction (typing) right where it bites, in the
   field after a visit.

Both fit the chat-first, on-device, notebook-simple spirit and build directly on what's already here.
