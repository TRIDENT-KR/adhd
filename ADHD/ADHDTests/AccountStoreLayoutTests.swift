import Foundation
import Testing
@testable import ADHD

struct AccountStoreLayoutTests {
    private let userA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let userB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test func namespaceIsStableHashedAndAccountSpecific() {
        let layout = AccountStoreLayout(
            applicationSupportURL: URL(fileURLWithPath: "/tmp/mora-tests", isDirectory: true)
        )

        #expect(
            layout.namespace(for: userA)
                == "4242a3bcf13673bba791a95451c6edd9463f3d678a6dba4953a59d2d8112feae"
        )
        #expect(layout.namespace(for: userA) != layout.namespace(for: userB))
        #expect(!layout.storeURL(for: userA).path.contains(userA.uuidString))
        #expect(layout.storeURL(for: userA).lastPathComponent == "Mora.sqlite")
    }

    @Test func sqliteFileListsAreExact() {
        let supportURL = URL(fileURLWithPath: "/tmp/mora-tests", isDirectory: true)
        let layout = AccountStoreLayout(applicationSupportURL: supportURL)

        #expect(layout.legacyStoreFiles.map(\.lastPathComponent) == [
            "default.store",
            "default.store-wal",
            "default.store-shm",
            "default.store-journal",
        ])
        #expect(layout.accountStoreFiles(for: userA).map(\.lastPathComponent) == [
            "Mora.sqlite",
            "Mora.sqlite-wal",
            "Mora.sqlite-shm",
            "Mora.sqlite-journal",
        ])
    }

    @Test func legacyCutoverRunsOnceAndPreservesUnlistedFiles() throws {
        let fileManager = FileManager.default
        let supportURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportURL) }

        try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let layout = AccountStoreLayout(applicationSupportURL: supportURL)
        for fileURL in layout.legacyStoreFiles {
            try Data("legacy".utf8).write(to: fileURL)
        }
        let unrelatedURL = supportURL.appendingPathComponent("keep.me")
        try Data("keep".utf8).write(to: unrelatedURL)

        let didPerformCutover = try LegacyStoreCutover.performIfNeeded(
            layout: layout,
            fileManager: fileManager
        )
        #expect(didPerformCutover)
        #expect(fileManager.fileExists(atPath: layout.legacyCutoverMarkerURL.path))
        #expect(layout.legacyStoreFiles.allSatisfy { !fileManager.fileExists(atPath: $0.path) })
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))

        let recreatedLegacyURL = layout.legacyStoreFiles[0]
        try Data("new".utf8).write(to: recreatedLegacyURL)
        let repeatedCutover = try LegacyStoreCutover.performIfNeeded(
            layout: layout,
            fileManager: fileManager
        )
        #expect(!repeatedCutover)
        #expect(fileManager.fileExists(atPath: recreatedLegacyURL.path))
    }

    @Test func completedDeletionRemovesOnlyExactAccountStoreFiles() throws {
        let fileManager = FileManager.default
        let supportURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: supportURL) }

        let layout = AccountStoreLayout(applicationSupportURL: supportURL)
        let accountDirectoryURL = layout.accountDirectoryURL(for: userA)
        try fileManager.createDirectory(
            at: accountDirectoryURL,
            withIntermediateDirectories: true
        )
        for fileURL in layout.accountStoreFiles(for: userA) {
            try Data("account".utf8).write(to: fileURL)
        }
        let unrelatedURL = accountDirectoryURL.appendingPathComponent("keep.me")
        try Data("keep".utf8).write(to: unrelatedURL)

        try CompletedAccountStoreDeletion.removeFiles(
            for: userA,
            layout: layout,
            fileManager: fileManager
        )

        #expect(
            layout.accountStoreFiles(for: userA)
                .allSatisfy { !fileManager.fileExists(atPath: $0.path) }
        )
        #expect(fileManager.fileExists(atPath: unrelatedURL.path))
    }

    @Test func accountPreferencesAreSeparatedAndDoNotExposeRawUUIDs() {
        let suiteName = "mora-account-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AccountPreferences.set(
            true,
            for: .confirmBeforeSave,
            userID: userA,
            defaults: defaults
        )
        AccountPreferences.set(
            false,
            for: .confirmBeforeSave,
            userID: userB,
            defaults: defaults
        )

        #expect(AccountPreferences.bool(
            .confirmBeforeSave,
            default: false,
            for: userA,
            defaults: defaults
        ))
        #expect(!AccountPreferences.bool(
            .confirmBeforeSave,
            default: true,
            for: userB,
            defaults: defaults
        ))
        let keys = defaults.dictionaryRepresentation().keys
        #expect(keys.allSatisfy { !$0.contains(userA.uuidString) })
        #expect(keys.allSatisfy { !$0.contains(userB.uuidString) })
    }

    private func temporaryDirectory(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("mora-account-store-\(UUID().uuidString)", isDirectory: true)
    }
}
