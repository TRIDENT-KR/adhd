import Combine
import CryptoKit
import Foundation
import SwiftData

/// 계정 UUID 원문을 디스크 경로에 남기지 않는 계정별 SwiftData 배치 규칙입니다.
struct AccountStoreLayout: Equatable {
    static let accountDirectoryName = "MoraAccounts"
    static let storeFileName = "Mora.sqlite"
    static let legacyStoreFileName = "default.store"
    static let legacyCutoverMarkerName = ".legacy-default-store-cutover-v1"

    let applicationSupportURL: URL

    var accountsRootURL: URL {
        applicationSupportURL.appendingPathComponent(Self.accountDirectoryName, isDirectory: true)
    }

    var legacyCutoverMarkerURL: URL {
        accountsRootURL.appendingPathComponent(Self.legacyCutoverMarkerName, isDirectory: false)
    }

    func namespace(for userID: UUID) -> String {
        let normalizedID = userID.uuidString.lowercased()
        return SHA256.hash(data: Data(normalizedID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func accountDirectoryURL(for userID: UUID) -> URL {
        accountsRootURL.appendingPathComponent(namespace(for: userID), isDirectory: true)
    }

    func storeURL(for userID: UUID) -> URL {
        accountDirectoryURL(for: userID)
            .appendingPathComponent(Self.storeFileName, isDirectory: false)
    }

    func accountStoreFiles(for userID: UUID) -> [URL] {
        Self.sqliteFiles(for: storeURL(for: userID))
    }

    var legacyStoreFiles: [URL] {
        let storeURL = applicationSupportURL
            .appendingPathComponent(Self.legacyStoreFileName, isDirectory: false)
        return Self.sqliteFiles(for: storeURL)
    }

    private static func sqliteFiles(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-journal"),
        ]
    }
}

/// 사용자가 없는 시점의 명시적 cutover입니다. marker가 생긴 뒤에는 다시 실행하지 않습니다.
enum LegacyStoreCutover {
    @discardableResult
    static func performIfNeeded(
        layout: AccountStoreLayout,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard !fileManager.fileExists(atPath: layout.legacyCutoverMarkerURL.path) else {
            return false
        }

        try fileManager.createDirectory(
            at: layout.accountsRootURL,
            withIntermediateDirectories: true
        )

        for fileURL in layout.legacyStoreFiles where fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        let marker = Data("legacy-default-store-reset-complete-v1".utf8)
        try marker.write(to: layout.legacyCutoverMarkerURL, options: .atomic)
        return true
    }
}

/// 서버의 계정 삭제 완료 신호를 받은 뒤에만 호출하는 정확 파일 삭제 연산입니다.
enum CompletedAccountStoreDeletion {
    static func removeFiles(
        for userID: UUID,
        layout: AccountStoreLayout,
        fileManager: FileManager = .default
    ) throws {
        for fileURL in layout.accountStoreFiles(for: userID)
        where fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}

@MainActor
final class AccountStoreController: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var activeUserID: UUID?
    @Published private(set) var failureCode: String?

    let layout: AccountStoreLayout
    private let fileManager: FileManager

    init(
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let supportURL = applicationSupportURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.layout = AccountStoreLayout(applicationSupportURL: supportURL)
        self.fileManager = fileManager
    }

    /// 인증이 확정된 Mora 사용자만 해당 물리 저장소를 열 수 있습니다.
    func activate(for userID: UUID) {
        if activeUserID == userID, container != nil {
            return
        }

        guard container == nil, activeUserID == nil else {
            failureCode = "MORA-DATA-SCOPE-001"
            return
        }

        do {
            try LegacyStoreCutover.performIfNeeded(layout: layout, fileManager: fileManager)

            let directoryURL = layout.accountDirectoryURL(for: userID)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let schema = Schema([AppTask.self])
            let configuration = ModelConfiguration(
                "MoraAccount",
                schema: schema,
                url: layout.storeURL(for: userID),
                allowsSave: true,
                cloudKitDatabase: .none
            )
            let accountContainer = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )

            container = accountContainer
            activeUserID = userID
            failureCode = nil
        } catch {
            // 저장 오류에서 파일을 자동 삭제하지 않습니다. 경로가 포함될 수 있어 원문도 기록하지 않습니다.
            failureCode = "MORA-DATA-001"
            print("account_store_open_failed code=MORA-DATA-001")
        }
    }

    /// 프레젠테이션 전용 인메모리 저장소. 배포 빌드에서는 호출되지 않습니다.
    func activatePresentationStore() {
        guard container == nil else { return }
        do {
            let schema = Schema([AppTask.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            container = try ModelContainer(for: schema, configurations: [configuration])
            failureCode = nil
        } catch {
            failureCode = "MORA-DATA-001"
            print("presentation_store_open_failed code=MORA-DATA-001")
        }
    }

    /// 메모리 참조만 해제합니다. 로그아웃·세션 무효에서는 디스크 파일을 보존합니다.
    func lock() {
        container = nil
        activeUserID = nil
        failureCode = nil
    }

    /// 서버 삭제 완료가 확인된 계정만 물리 파일을 제거합니다.
    func deleteStoreAfterServerCompletion(for userID: UUID) {
        if activeUserID == userID {
            lock()
        }

        do {
            try CompletedAccountStoreDeletion.removeFiles(
                for: userID,
                layout: layout,
                fileManager: fileManager
            )
            failureCode = nil
        } catch {
            failureCode = "MORA-DATA-DELETE-001"
            print("account_store_delete_failed code=MORA-DATA-DELETE-001")
        }
    }
}
