# Harvest Shortcuts & Siri Guide

All of Harvest's automations run on-device through App Intents. No setup is needed for the
spoken phrases below — Siri and Spotlight surface them automatically.

## Spoken phrases

- "Add a return visit in Harvest"
- "Who's due in Harvest"
- "Add a note in Harvest"
- "Log a not-at-home in Harvest"
- "Start a territory in Harvest"
- "Back up Harvest"
- "Log a visit in Harvest" — dictate the whole note; the on-device model parses and files it, then speaks a confirmation.
- "Start a service session in Harvest"
- "Stop my session in Harvest"

## Auto-start a session when you arrive at a territory

iOS location automations live in the Shortcuts app (Harvest provides the action; iOS owns the trigger):

1. Open the **Shortcuts** app → **Automation** tab.
2. **Create Personal Automation** → **Arrive**.
3. Pick the territory's location and radius.
4. Add action: search **"Start Service Session"** (Harvest). Optionally set the Territory name.
5. Turn on **Run Immediately** / **Run Without Asking**.

The session begins automatically when iOS detects arrival. Pair with an **Leave** automation
running **"Stop Service Session"** to close it out hands-free.
