import Foundation
import Testing
import SwiftData
import AuthenticationServices
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

struct AIDataConsentTests {
    @Test func consentRequiresOptInAndIsIsolatedAndDeletedWithAccount() throws {
        let name = "consent-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID(), second = UUID()
        #expect(!AIDataConsent.isGranted(for: first, defaults: defaults))
        AIDataConsent.setGranted(true, for: first, defaults: defaults)
        #expect(AIDataConsent.isGranted(for: first, defaults: defaults))
        #expect(!AIDataConsent.isGranted(for: second, defaults: defaults))
        AIDataConsent.setGranted(false, for: first, defaults: defaults)
        #expect(!AIDataConsent.isGranted(for: first, defaults: defaults))
        AIDataConsent.setGranted(true, for: first, defaults: defaults)
        AccountPreferences.removeAll(for: first, defaults: defaults)
        #expect(!AIDataConsent.isGranted(for: first, defaults: defaults))
    }
    @Test func outdatedConsentCannotAuthorizeANewDisclosure() throws {
        let name = "consent-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let user = UUID()
        AccountPreferences.set(AIDataConsent.currentVersion - 1, for: .aiDataConsentVersion, userID: user, defaults: defaults)
        #expect(!AIDataConsent.isGranted(for: user, defaults: defaults))
    }
}

@MainActor
struct GuestAccountStorageTests {
    @Test func guestIdentityNeverBecomesAnAuthenticatedIdentity() {
        for state in [AuthAccessState.signedOut, .lockedInvalidSession] {
            #expect(state.isGuest)
            #expect(state.localStorageUserID == LocalGuestIdentity.storageID)
            #expect(state.accountUserID == nil)
            #expect(state.exposedUserID == nil)
        }
        let realUser = UUID()
        #expect(AuthAccessState.authenticatedOnline(userID: realUser).accountUserID == realUser)
        #expect(!AuthAccessState.authenticatedOnline(userID: realUser).isGuest)
        #expect(AuthAccessState.deletionPending(userID: realUser).localStorageUserID == nil)
    }

    @Test func guestSurvivesReopeningAndExplicitCopyDoesNotOverwriteEitherStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mora-guest-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AccountStoreController(applicationSupportURL: directory)
        let firstAccount = UUID(), secondAccount = UUID()
        controller.activate(for: LocalGuestIdentity.storageID)
        let guestContext = try #require(controller.container?.mainContext)
        let original = AppTask(
            task: "Guest appointment", time: "09:30 AM", date: Date(timeIntervalSince1970: 1_800_000_000),
            category: "Appointment", recurrenceRule: "monthly", sortOrder: 4, urgency: .weak
        )
        let expectedWeeklyCompletions = [true, false, true, false, false, false, false]
        original.weeklyCompletions = expectedWeeklyCompletions
        let originalID = original.id
        guestContext.insert(original)
        #expect(controller.saveBeforeSwitch())
        controller.lock()

        controller.activate(for: firstAccount)
        let accountContext = try #require(controller.container?.mainContext)
        #expect(try accountContext.fetchCount(FetchDescriptor<AppTask>()) == 0)
        #expect(controller.layout.storeURL(for: firstAccount) != controller.layout.storeURL(for: LocalGuestIdentity.storageID))
        #expect(try controller.copyGuestTasks(to: firstAccount) == 1)
        let imported = try #require(accountContext.fetch(FetchDescriptor<AppTask>()).first)
        #expect(imported.id == originalID)
        #expect(imported.recurrenceRule == "monthly")
        // The original model becomes invalid when its container is locked; compare value snapshots.
        #expect(imported.weeklyCompletions == expectedWeeklyCompletions)
        #expect(imported.urgency == .weak)
        imported.task = "Account edit"
        try accountContext.save()
        #expect(try controller.copyGuestTasks(to: firstAccount) == 0)
        #expect(imported.task == "Account edit")
        #expect(throws: GuestTaskImportError.self) {
            try controller.copyGuestTasks(to: secondAccount)
        }
        controller.lock()

        let reopened = AccountStoreController(applicationSupportURL: directory)
        reopened.activate(for: LocalGuestIdentity.storageID)
        let preserved = try #require(reopened.container?.mainContext.fetch(FetchDescriptor<AppTask>()).first)
        #expect(preserved.id == originalID)
        #expect(preserved.task == "Guest appointment")
        reopened.lock()

        controller.activate(for: secondAccount)
        #expect(try controller.container?.mainContext.fetchCount(FetchDescriptor<AppTask>()) == 0)
        #expect(try controller.copyGuestTasks(to: secondAccount) == 1)
        controller.lock()
    }

    @Test func guestPreferencesAndAccountDeletionStayIsolated() throws {
        let name = "guest-preferences-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let user = UUID()
        AccountPreferences.set(true, for: .routineRemindersDisabled, userID: LocalGuestIdentity.storageID, defaults: defaults)
        AccountPreferences.set(false, for: .routineRemindersDisabled, userID: user, defaults: defaults)
        AccountPreferences.removeAll(for: user, defaults: defaults)
        #expect(AccountPreferences.bool(.routineRemindersDisabled, default: false, for: LocalGuestIdentity.storageID, defaults: defaults))
        #expect(!AccountPreferences.bool(.routineRemindersDisabled, default: false, for: user, defaults: defaults))
    }
}

@MainActor
struct AccountDeletionRecoveryTests {
    private final class Journal: AccountDeletionPersistence {
        var data: Data?
        var failSave = false
        var failClear = false
        func load() -> PendingAccountDeletion? {
            data.flatMap { try? JSONDecoder().decode(PendingAccountDeletion.self, from: $0) }
        }
        func save(_ pending: PendingAccountDeletion) throws {
            if failSave { throw AccountDeletionClientError.statusUnavailable }
            data = try JSONEncoder().encode(pending)
        }
        func clear() throws {
            if failClear { throw AccountDeletionClientError.statusUnavailable }
            data = nil
        }
    }

    @Test func statusReauthenticationErrorPersistsAndCannotResumePollingAfterRelaunch() async throws {
        let journal = Journal()
        let user = UUID(), request = UUID()
        try journal.save(PendingAccountDeletion(
            userID: user, requestID: request, jobID: nil, status: .retryWait,
            statusToken: String(repeating: "a", count: 43), needsAppleReauthentication: false
        ))
        let name = "deletion-reauth-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        let response = try JSONDecoder().decode(AccountDeletionServerError.self, from: Data("""
        {"error":{"code":"apple_reauth_required"},"requestId":"\(request)","status":"retry_wait"}
        """.utf8))
        try manager.handleDeletionStatusServerError(response)
        #expect(manager.accountDeletionNeedsAppleReauthentication)
        #expect(journal.load()?.shouldPoll == false)

        let relaunched = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        await relaunched.checkSession()
        #expect(relaunched.accountDeletionNeedsAppleReauthentication)
        #expect(relaunched.accessState == .deletionPending(userID: user))
        #expect(journal.load()?.requestID == request)
    }

    @Test func serverCompletionRemainsDurableUntilLocalCleanupAndJournalClearSucceed() async throws {
        let journal = Journal()
        let user = UUID()
        try journal.save(PendingAccountDeletion(
            userID: user, requestID: UUID(), jobID: nil, status: .running,
            statusToken: String(repeating: "b", count: 43), needsAppleReauthentication: false
        ))
        let name = "deletion-cleanup-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        manager.confirmAccountDeletionCompleted(for: user)
        #expect(manager.pendingLocalDeletionUserID == user)
        #expect(!manager.showsDeletionCompletion)
        #expect(journal.load()?.shouldPoll == false)

        // Termination (or file deletion failure) before local completion must retain the work.
        let relaunched = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        await relaunched.checkSession()
        #expect(relaunched.pendingLocalDeletionUserID == user)
        #expect(relaunched.accessState == .deletionPending(userID: user))
        journal.failClear = true
        #expect(throws: AccountDeletionClientError.self) {
            try relaunched.finishLocalAccountDeletion(for: user)
        }
        #expect(relaunched.pendingLocalDeletionUserID == user)
        #expect(!relaunched.showsDeletionCompletion)
        journal.failClear = false
        try relaunched.finishLocalAccountDeletion(for: user)
        #expect(journal.load() == nil)
        #expect(relaunched.accessState == .signedOut)
        #expect(relaunched.showsDeletionCompletion)

        let afterCleanup = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        #expect(afterCleanup.showsDeletionCompletion)
        afterCleanup.dismissDeletionCompletion()
        #expect(!afterCleanup.showsDeletionCompletion)
    }

    @Test func failedDurableCompletionWriteDoesNotDiscardThePendingRequest() throws {
        let journal = Journal()
        let user = UUID(), request = UUID()
        try journal.save(PendingAccountDeletion(
            userID: user, requestID: request, jobID: nil, status: .running,
            statusToken: String(repeating: "c", count: 43), needsAppleReauthentication: false
        ))
        let name = "deletion-write-failure-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AuthManager(deletionPollingStore: journal, deletionNoticeDefaults: defaults, observesAuthentication: false)
        journal.failSave = true
        manager.confirmAccountDeletionCompleted(for: user)
        #expect(journal.load()?.requestID == request)
        #expect(journal.load()?.status == .running)
        #expect(manager.pendingLocalDeletionUserID == nil)
        #expect(!manager.showsDeletionCompletion)
    }

    @Test func signInFailureIsVisibleButUserCancellationIsNotAnError() throws {
        let name = "sign-in-errors-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = AuthManager(deletionPollingStore: Journal(), deletionNoticeDefaults: defaults, observesAuthentication: false)
        manager.handleAppleSignInResult(.failure(URLError(.notConnectedToInternet)))
        #expect(manager.signInFailed)
        #expect(!manager.isProcessing)
        manager.handleAppleSignInResult(.failure(NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )))
        #expect(!manager.signInFailed)
        #expect(!manager.isProcessing)
    }
}

@MainActor
struct AuthSessionTransitionTests {
    @Test func lateSessionValidationAndProviderEventsCannotUndoSignOut() {
        var guardState = AuthSessionTransitionGuard(isLocallyLocked: false)
        let validationGeneration = guardState.generation
        #expect(guardState.permitsBackgroundResult(validationGeneration))
        guardState.invalidate()
        #expect(!guardState.permitsBackgroundResult(validationGeneration))
        #expect(!guardState.permitsBackgroundResult(guardState.generation))
        let relaunched = AuthSessionTransitionGuard(isLocallyLocked: true)
        #expect(!relaunched.permitsBackgroundResult(relaunched.generation))
    }

    @Test func onlyCurrentExplicitSignInCanReopenSessionAccess() {
        var guardState = AuthSessionTransitionGuard(isLocallyLocked: true)
        let first = guardState.beginInteractiveSignIn()
        #expect(!guardState.permitsBackgroundResult(first))
        guardState.invalidate() // Sign out or invalidation while Apple/Supabase is still returning.
        let acceptsInvalidatedAttempt = guardState.finishInteractiveSignIn(first, succeeded: true)
        #expect(!acceptsInvalidatedAttempt)
        #expect(!guardState.allowsBackgroundSession)
        let second = guardState.beginInteractiveSignIn()
        let acceptsSupersededAttempt = guardState.finishInteractiveSignIn(first, succeeded: true)
        #expect(!acceptsSupersededAttempt)
        let acceptsCurrentAttempt = guardState.finishInteractiveSignIn(second, succeeded: true)
        #expect(acceptsCurrentAttempt)
        #expect(guardState.permitsBackgroundResult(second))
        #expect(!guardState.permitsBackgroundResult(first))
    }

    @Test func newerAcceptedSessionInvalidatesOlderChecksAndCancellationKeepsGuestLocked() {
        var guardState = AuthSessionTransitionGuard(isLocallyLocked: false)
        let olderCheck = guardState.generation
        guardState.didAcceptSession()
        #expect(!guardState.permitsBackgroundResult(olderCheck))
        let attempt = guardState.beginInteractiveSignIn()
        let acceptsCancellation = guardState.finishInteractiveSignIn(attempt, succeeded: false)
        #expect(acceptsCancellation)
        #expect(!guardState.permitsBackgroundResult(guardState.generation))
    }

    @Test func sessionExpiryCheckRunsAfterTheExpiryBoundary() {
        let now: TimeInterval = 1_800_000_000
        let expiresAt = now + 60
        let delay = AuthSessionTransitionGuard.expiryCheckDelay(expiresAt: expiresAt, now: now)
        #expect(now + delay > expiresAt)
        #expect(delay < 61)
        #expect(AuthSessionTransitionGuard.expiryCheckDelay(expiresAt: now - 1, now: now) == 0.1)
    }
}
