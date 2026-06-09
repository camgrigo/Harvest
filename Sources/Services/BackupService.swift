import Foundation
import SwiftData
import CryptoKit
import LocalAuthentication

/// How a backup's encryption key is obtained. Passphrase is the original, always-available path;
/// biometric stores a random key in the Keychain behind Face ID / Touch ID for unlock convenience,
/// but the passphrase remains the durable fallback for restoring on any device.
enum KeyDerivationStrategy {
    case passphrase(String)
    case biometric
}

/// On-device, end-to-end-private backup. The entire notebook is serialised to JSON and encrypted
/// with AES-GCM using a key derived from the user's passphrase (HKDF-SHA256 + a random salt). The
/// resulting file never leaves the device unless the user shares it, and can't be opened without
/// the passphrase. Restore replaces everything with the backup's contents.
enum BackupService {

    enum BackupError: LocalizedError {
        case wrongPassphrase
        case badFile
        case biometricsUnavailable
        case biometricAuthFailed(String)
        case keychainError
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase: "That passphrase doesn't match this backup."
            case .badFile: "This file isn't a Harvest backup."
            case .biometricsUnavailable: "Face ID is not available on this device."
            case .biometricAuthFailed(let msg): "Face ID authentication failed: \(msg)"
            case .keychainError: "Failed to access the secure backup key."
            case .iCloudUnavailable: "iCloud Drive is not available. Check Settings > Apple ID > iCloud."
            }
        }
    }

    /// The app's iCloud Drive (ubiquity) container. Requires the iCloud Documents capability to be
    /// enabled in Xcode; without it this returns nil and auto-backup reports `iCloudUnavailable`.
    static let ubiquityContainerIdentifier = "iCloud.com.camgrigo.ReturnVisitNotebook"
    private static let keychainAccount = "com.camgrigo.harvest.backup.key"
    private static let keychainService = "Harvest Backup"

    // MARK: Public API

    /// Synchronous, passphrase-only backup (the original path). Used by the share-sheet export and
    /// the auto-backup task; needs no user presence beyond having typed the passphrase.
    @MainActor
    static func makeBackup(context: ModelContext, passphrase: String) throws -> Data {
        let snapshot = try snapshot(from: context)
        let json = try JSONEncoder().encode(snapshot)
        return try encrypt(json, passphrase: passphrase)
    }

    /// Synchronous, passphrase-only restore (the original path).
    @MainActor
    static func restore(from data: Data, passphrase: String, into context: ModelContext) throws {
        let json = try decrypt(data, passphrase: passphrase)
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: json) else {
            throw BackupError.badFile
        }
        try clearAll(context)
        apply(snapshot, into: context)
    }

    /// Backup honoring the chosen strategy. Biometric authenticates with Face ID, mints a random
    /// 256-bit key, and stores it behind biometric Keychain access; passphrase is the fallback.
    @MainActor
    static func makeBackup(context: ModelContext, strategy: KeyDerivationStrategy) async throws -> Data {
        let snapshot = try snapshot(from: context)
        let json = try JSONEncoder().encode(snapshot)
        switch strategy {
        case .passphrase(let phrase):
            return try encrypt(json, passphrase: phrase)
        case .biometric:
            _ = try await authenticateWithBiometrics()
            let key = SymmetricKey(size: .bits256)
            try storeKeyInKeychain(key)
            let sealed = try AES.GCM.seal(json, using: key)
            guard let combined = sealed.combined else { throw BackupError.badFile }
            // Prefix with 16 zero bytes so the file layout matches the passphrase format (salt slot).
            return Data(count: 16) + combined
        }
    }

    /// Restore honoring the chosen strategy.
    @MainActor
    static func restore(from data: Data, strategy: KeyDerivationStrategy, into context: ModelContext) async throws {
        let json: Data
        switch strategy {
        case .passphrase(let phrase):
            json = try decrypt(data, passphrase: phrase)
        case .biometric:
            _ = try await authenticateWithBiometrics()
            guard let key = retrieveKeyFromKeychain() else { throw BackupError.keychainError }
            guard data.count > 16 else { throw BackupError.badFile }
            let body = data.suffix(from: data.startIndex + 16)
            do {
                let box = try AES.GCM.SealedBox(combined: body)
                json = try AES.GCM.open(box, using: key)
            } catch {
                throw BackupError.keychainError
            }
        }
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: json) else {
            throw BackupError.badFile
        }
        try clearAll(context)
        apply(snapshot, into: context)
    }

    // MARK: Biometrics

    /// Prompts for Face ID / Touch ID. Throws `biometricsUnavailable` if no biometry is enrolled.
    @MainActor
    static func authenticateWithBiometrics() async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw BackupError.biometricsUnavailable
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock your backup with Face ID")
        } catch {
            throw BackupError.biometricAuthFailed(error.localizedDescription)
        }
    }

    private static func storeKeyInKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = keyData
        if let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            nil) {
            add[kSecAttrAccessControl as String] = access
        } else {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw BackupError.keychainError }
    }

    private static func retrieveKeyFromKeychain() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: Auto backup (iCloud Drive)

    /// Writes a fresh passphrase-encrypted backup into the app's iCloud Drive `Backups/` folder.
    /// Biometric keys are intentionally not used here — auto-backup runs with no user present.
    @MainActor
    static func autoBackupToiCloud(context: ModelContext, passphrase: String) throws {
        let data = try makeBackup(context: context, passphrase: passphrase)
        guard let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: ubiquityContainerIdentifier) else {
            throw BackupError.iCloudUnavailable
        }
        let dir = iCloudURL.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "Harvest-auto-\(DateFormatter.isoDateTime.string(from: .now)).harvestbackup"
        try data.write(to: dir.appendingPathComponent(filename), options: .atomic)
    }

    /// Deletes auto-backups older than `days` to keep the iCloud folder from growing unbounded.
    @MainActor
    static func pruneOldAutoBackups(olderThan days: Int = 30) {
        guard let iCloudURL = FileManager.default.url(
            forUbiquityContainerIdentifier: ubiquityContainerIdentifier) else { return }
        let dir = iCloudURL.appendingPathComponent("Backups", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        for file in files where file.lastPathComponent.hasPrefix("Harvest-auto-") {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date, modDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Auto-backup passphrase (Keychain)

    private static let autoPassphraseAccount = "com.camgrigo.harvest.backup.autopassphrase"

    /// Stores the passphrase the background task uses, in the Keychain (accessible after first
    /// unlock so the task can run while the device is locked). Pass nil/empty to clear it.
    static func setAutoBackupPassphrase(_ passphrase: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoPassphraseAccount,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(base as CFDictionary)
        guard let passphrase, !passphrase.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(passphrase.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    /// Reads the stored auto-backup passphrase, if any.
    static func autoBackupPassphrase() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: autoPassphraseAccount,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Encryption

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(passphrase.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                      info: Data("harvest.backup.v1".utf8), outputByteCount: 32)
    }

    private static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw BackupError.badFile }
        return salt + combined
    }

    private static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        guard data.count > 16 else { throw BackupError.badFile }
        let salt = data.prefix(16)
        let body = data.suffix(from: data.startIndex + 16)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: body)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BackupError.wrongPassphrase
        }
    }

    // MARK: Snapshot model

    private struct Snapshot: Codable {
        var version = 1
        var people: [PersonDTO]
        var entries: [EntryDTO]
        var territories: [TerritoryDTO]
        var doors: [DoorDTO]
        var doNotCalls: [DoNotCallDTO]
        var chats: [ChatDTO]
        var servicePlans: [ServicePlanDTO]?   // optional → older backups still decode
    }

    private struct PersonDTO: Codable {
        var id: UUID, name: String, addressText: String
        var latitude: Double?, longitude: Double?
        var interestRaw: String, createdAt: Date
        var nextVisitDate: Date?, isArchived: Bool, headline: String
    }
    private struct EntryDTO: Codable {
        var date: Date, text: String, topic: String, scripture: String, publication: String
        var deletedAt: Date?, personID: UUID?
    }
    private struct TerritoryDTO: Codable {
        var id: UUID, name: String, createdAt: Date, lastWorkedAt: Date?
        var latitude: Double?, longitude: Double?, urlString: String?, mapImageData: Data?
    }
    private struct DoorDTO: Codable {
        var id: UUID, address: String, latitude: Double?, longitude: Double?
        var createdAt: Date, lastTriedAt: Date, attemptCount: Int, note: String
        var attemptTimes: [Date], territoryID: UUID?
    }
    private struct DoNotCallDTO: Codable {
        var id: UUID, address: String, latitude: Double?, longitude: Double?
        var createdAt: Date, territoryID: UUID?
    }
    private struct ChatDTO: Codable {
        var date: Date, text: String, isFromUser: Bool, isCleared: Bool, personID: UUID?
    }
    private struct ServicePlanDTO: Codable {
        var id: UUID, date: Date, durationMinutes: Int
        var place: String, partner: String, note: String, createdAt: Date
    }

    // MARK: Capture

    @MainActor
    private static func snapshot(from context: ModelContext) throws -> Snapshot {
        let people = try context.fetch(FetchDescriptor<Person>())
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let territories = try context.fetch(FetchDescriptor<Territory>())
        let doors = try context.fetch(FetchDescriptor<NotAtHome>())
        let doNotCalls = try context.fetch(FetchDescriptor<DoNotCall>())
        let chats = try context.fetch(FetchDescriptor<ChatMessage>())
        let servicePlans = try context.fetch(FetchDescriptor<ServicePlan>())

        return Snapshot(
            people: people.map {
                PersonDTO(id: $0.id, name: $0.name, addressText: $0.addressText,
                          latitude: $0.latitude, longitude: $0.longitude,
                          interestRaw: $0.interestRaw, createdAt: $0.createdAt,
                          nextVisitDate: $0.nextVisitDate, isArchived: $0.isArchived,
                          headline: $0.headline)
            },
            entries: entries.map {
                EntryDTO(date: $0.date, text: $0.text, topic: $0.topic, scripture: $0.scripture,
                         publication: $0.publication, deletedAt: $0.deletedAt, personID: $0.person?.id)
            },
            territories: territories.map {
                TerritoryDTO(id: $0.id, name: $0.name, createdAt: $0.createdAt,
                             lastWorkedAt: $0.lastWorkedAt, latitude: $0.latitude,
                             longitude: $0.longitude, urlString: $0.urlString,
                             mapImageData: $0.mapImageData)
            },
            doors: doors.map {
                DoorDTO(id: $0.id, address: $0.address, latitude: $0.latitude, longitude: $0.longitude,
                        createdAt: $0.createdAt, lastTriedAt: $0.lastTriedAt, attemptCount: $0.attemptCount,
                        note: $0.note, attemptTimes: $0.attemptTimes, territoryID: $0.territory?.id)
            },
            doNotCalls: doNotCalls.map {
                DoNotCallDTO(id: $0.id, address: $0.address, latitude: $0.latitude,
                            longitude: $0.longitude, createdAt: $0.createdAt, territoryID: $0.territory?.id)
            },
            chats: chats.map {
                ChatDTO(date: $0.date, text: $0.text, isFromUser: $0.isFromUser,
                        isCleared: $0.isCleared, personID: $0.person?.id)
            },
            servicePlans: servicePlans.map {
                ServicePlanDTO(id: $0.id, date: $0.date, durationMinutes: $0.durationMinutes,
                               place: $0.place, partner: $0.partner, note: $0.note, createdAt: $0.createdAt)
            }
        )
    }

    // MARK: Restore

    @MainActor
    private static func clearAll(_ context: ModelContext) throws {
        for p in try context.fetch(FetchDescriptor<Person>()) { context.delete(p) }
        for t in try context.fetch(FetchDescriptor<Territory>()) { context.delete(t) }
        for e in try context.fetch(FetchDescriptor<JournalEntry>()) { context.delete(e) }
        for d in try context.fetch(FetchDescriptor<NotAtHome>()) { context.delete(d) }
        for d in try context.fetch(FetchDescriptor<DoNotCall>()) { context.delete(d) }
        for c in try context.fetch(FetchDescriptor<ChatMessage>()) { context.delete(c) }
        for p in try context.fetch(FetchDescriptor<ServicePlan>()) { context.delete(p) }
        context.saveIfPossible()
    }

    @MainActor
    private static func apply(_ s: Snapshot, into context: ModelContext) {
        var peopleByID: [UUID: Person] = [:]
        for dto in s.people {
            let p = Person(name: dto.name, addressText: dto.addressText,
                           interest: InterestLevel(rawValue: dto.interestRaw) ?? .new,
                           createdAt: dto.createdAt)
            p.id = dto.id
            p.latitude = dto.latitude
            p.longitude = dto.longitude
            p.nextVisitDate = dto.nextVisitDate
            p.isArchived = dto.isArchived
            p.headline = dto.headline
            context.insert(p)
            peopleByID[dto.id] = p
        }

        var territoriesByID: [UUID: Territory] = [:]
        for dto in s.territories {
            let t = Territory(name: dto.name, latitude: dto.latitude, longitude: dto.longitude,
                              createdAt: dto.createdAt)
            t.id = dto.id
            t.lastWorkedAt = dto.lastWorkedAt
            t.urlString = dto.urlString
            t.mapImageData = dto.mapImageData
            context.insert(t)
            territoriesByID[dto.id] = t
        }

        for dto in s.entries {
            let e = JournalEntry(date: dto.date, text: dto.text, topic: dto.topic,
                                 scripture: dto.scripture, publication: dto.publication,
                                 person: dto.personID.flatMap { peopleByID[$0] })
            e.deletedAt = dto.deletedAt
            context.insert(e)
        }

        for dto in s.doors {
            let d = NotAtHome(address: dto.address, latitude: dto.latitude, longitude: dto.longitude,
                              note: dto.note, createdAt: dto.createdAt)
            d.id = dto.id
            d.lastTriedAt = dto.lastTriedAt
            d.attemptCount = dto.attemptCount
            d.attemptTimes = dto.attemptTimes
            d.territory = dto.territoryID.flatMap { territoriesByID[$0] }
            context.insert(d)
        }

        for dto in s.doNotCalls {
            let dnc = DoNotCall(address: dto.address, latitude: dto.latitude,
                                longitude: dto.longitude, createdAt: dto.createdAt)
            dnc.id = dto.id
            dnc.territory = dto.territoryID.flatMap { territoriesByID[$0] }
            context.insert(dnc)
        }

        for dto in s.chats {
            let c = ChatMessage(date: dto.date, text: dto.text, isFromUser: dto.isFromUser,
                                isCleared: dto.isCleared, person: dto.personID.flatMap { peopleByID[$0] })
            context.insert(c)
        }

        for dto in s.servicePlans ?? [] {
            let p = ServicePlan(date: dto.date, durationMinutes: dto.durationMinutes,
                                place: dto.place, partner: dto.partner, note: dto.note,
                                createdAt: dto.createdAt)
            p.id = dto.id
            context.insert(p)
        }

        context.saveIfPossible()
    }
}
