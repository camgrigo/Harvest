import Foundation
import SwiftData
import CryptoKit

/// On-device, end-to-end-private backup. The entire notebook is serialised to JSON and encrypted
/// with AES-GCM using a key derived from the user's passphrase (HKDF-SHA256 + a random salt). The
/// resulting file never leaves the device unless the user shares it, and can't be opened without
/// the passphrase. Restore replaces everything with the backup's contents.
enum BackupService {

    enum BackupError: LocalizedError {
        case wrongPassphrase
        case badFile

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase: "That passphrase doesn't match this backup."
            case .badFile: "This file isn't a Harvest backup."
            }
        }
    }

    // MARK: Public API

    @MainActor
    static func makeBackup(context: ModelContext, passphrase: String) throws -> Data {
        let snapshot = try snapshot(from: context)
        let json = try JSONEncoder().encode(snapshot)
        return try encrypt(json, passphrase: passphrase)
    }

    @MainActor
    static func restore(from data: Data, passphrase: String, into context: ModelContext) throws {
        let json = try decrypt(data, passphrase: passphrase)
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: json) else {
            throw BackupError.badFile
        }
        try clearAll(context)
        apply(snapshot, into: context)
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

    // MARK: Capture

    @MainActor
    private static func snapshot(from context: ModelContext) throws -> Snapshot {
        let people = try context.fetch(FetchDescriptor<Person>())
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let territories = try context.fetch(FetchDescriptor<Territory>())
        let doors = try context.fetch(FetchDescriptor<NotAtHome>())
        let doNotCalls = try context.fetch(FetchDescriptor<DoNotCall>())
        let chats = try context.fetch(FetchDescriptor<ChatMessage>())

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

        context.saveIfPossible()
    }
}
