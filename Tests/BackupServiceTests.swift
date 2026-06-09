import XCTest
import SwiftData
import CryptoKit
@testable import Harvest

@MainActor
final class BackupServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Person.self, JournalEntry.self, ChatMessage.self, NotAtHome.self,
            Territory.self, DoNotCall.self, ServicePlan.self, CongregationBoundary.self,
            configurations: config
        )
        return ModelContext(container)
    }

    // MARK: Encryption round-trip

    func testPassphraseEncryptDecryptRoundTrip() throws {
        let context = try makeContext()
        context.insert(Person(name: "Test"))
        context.saveIfPossible()

        let passphrase = "test-passphrase-12345"
        let encrypted = try BackupService.makeBackup(context: context, passphrase: passphrase)
        XCTAssertGreaterThan(encrypted.count, 0)

        let context2 = try makeContext()
        try BackupService.restore(from: encrypted, passphrase: passphrase, into: context2)

        let restored = try context2.fetch(FetchDescriptor<Person>())
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.name, "Test")
    }

    func testWrongPassphraseThrows() throws {
        let context = try makeContext()
        context.insert(Person(name: "Alice"))
        context.saveIfPossible()

        let encrypted = try BackupService.makeBackup(context: context, passphrase: "correct")
        let context2 = try makeContext()

        XCTAssertThrowsError(
            try BackupService.restore(from: encrypted, passphrase: "wrong", into: context2)
        ) { error in
            XCTAssertTrue(error is BackupService.BackupError)
        }
    }

    func testMultipleEntitiesPreserved() throws {
        let context = try makeContext()
        let p1 = Person(name: "Alice")
        let t1 = Territory(name: "Downtown")
        let e1 = JournalEntry(text: "Good visit", person: p1)
        context.insert(p1)
        context.insert(t1)
        context.insert(e1)
        context.saveIfPossible()

        let encrypted = try BackupService.makeBackup(context: context, passphrase: "test")
        let context2 = try makeContext()
        try BackupService.restore(from: encrypted, passphrase: "test", into: context2)

        XCTAssertEqual(try context2.fetch(FetchDescriptor<Person>()).count, 1)
        XCTAssertEqual(try context2.fetch(FetchDescriptor<Territory>()).count, 1)
        let entries = try context2.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "Good visit")
    }

    func testRandomSaltGivesDifferentCiphertext() throws {
        let context = try makeContext()
        context.insert(Person(name: "Test"))
        context.saveIfPossible()

        let passphrase = "test"
        let backup1 = try BackupService.makeBackup(context: context, passphrase: passphrase)
        let backup2 = try BackupService.makeBackup(context: context, passphrase: passphrase)
        XCTAssertNotEqual(backup1, backup2)

        let ctx1 = try makeContext()
        try BackupService.restore(from: backup1, passphrase: passphrase, into: ctx1)
        let ctx2 = try makeContext()
        try BackupService.restore(from: backup2, passphrase: passphrase, into: ctx2)
        XCTAssertEqual(
            try ctx1.fetch(FetchDescriptor<Person>()).first?.name,
            try ctx2.fetch(FetchDescriptor<Person>()).first?.name)
    }

    func testCorruptedBackupThrows() throws {
        let context = try makeContext()
        let corrupted = Data([0xFF, 0xFE, 0xFD])
        XCTAssertThrowsError(
            try BackupService.restore(from: corrupted, passphrase: "test", into: context)
        ) { error in
            XCTAssertTrue(error is BackupService.BackupError)
        }
    }

    // MARK: iCloud availability

    func testAutoBackupThrowsWhenICloudUnavailable() throws {
        // In the test host there's no ubiquity container, so this must surface iCloudUnavailable
        // rather than crashing. (If a container ever IS present, the write simply succeeds.)
        let context = try makeContext()
        context.insert(Person(name: "Test"))
        context.saveIfPossible()
        let hasICloud = FileManager.default.url(
            forUbiquityContainerIdentifier: BackupService.ubiquityContainerIdentifier) != nil
        if !hasICloud {
            XCTAssertThrowsError(
                try BackupService.autoBackupToiCloud(context: context, passphrase: "test")
            ) { error in
                XCTAssertEqual(error as? BackupService.BackupError, .iCloudUnavailable)
            }
        }
    }

    // MARK: Schedule date math

    func testNextBackupDateIsRoughlyOneDayOut() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let next = HarvestApp.nextBackupDate(after: now)
        XCTAssertEqual(next.timeIntervalSince(now), 24 * 3600, accuracy: 1)
    }

    // MARK: CloudKit feature flag

    func testCloudKitDisabledByDefault() {
        XCTAssertFalse(FeatureFlags.cloudKitEnabled)
        // Container still builds even when cloudKit is requested (flag overrides to local store).
        _ = AppModelContainer.make(inMemory: true, cloudKit: true)
    }
}

extension BackupService.BackupError: Equatable {
    public static func == (lhs: BackupService.BackupError, rhs: BackupService.BackupError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
