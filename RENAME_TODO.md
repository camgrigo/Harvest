# TODO: Cosmetic rename "Harvest" → "Service Day"

Scope decided: **cosmetic only.** Rename code symbols / scheme / user-facing
voice strings. Do **NOT** touch identity/persistence strings — changing those
orphans on-device app data and makes existing encrypted backups undecryptable.

## Rename (safe — cosmetic)
- `Sources/App.swift:6` — `struct HarvestApp: App` → `ServiceDayApp`
  - update refs: `Tests/BackupServiceTests.swift:126`, `Sources/Views/SettingsView.swift:78`
- `Sources/Intents/HarvestIntents.swift` — types `BackupHarvestIntent` (l.150),
  `HarvestShortcuts` (l.289), and ref at l.339; consider renaming the file too.
- Voice/Siri strings in `HarvestIntents.swift` (l.5, 36, 186, 213, 266): "…in Harvest" → "…in Service Day".
- Module name `Harvest` → would require renaming the Xcode target/scheme +
  all `@testable import Harvest` (18 test files). Bigger change; do only if wanted.
  Note: keep the **bundle ID** as `com.camgrigo.harvest*` so the app installs
  over the existing one (no data loss).

## DO NOT CHANGE (identity / persistence — would break the live app)
- `com.camgrigo.harvest.backup` — BGTask id (`Sources/App.swift`, `Sources/Info.plist`)
- Keychain: `"Harvest Backup"`, `com.camgrigo.harvest.backup.key`,
  `com.camgrigo.harvest.backup.autopassphrase` (`BackupService.swift`)
- `@AppStorage("harvest.autoBackupEnabled")` (`SettingsView.swift:31`)
- `"harvest.backup.v1"` — HKDF key-derivation input (`BackupService.swift:244`) ⚠️
- `.harvestbackup` extension; `Harvest-auto-` / `Harvest-backup-` filename prefixes
  (`BackupService.swift:183,197`, `SettingsView.swift:45`) — prefixes drive cleanup matching.
