import Foundation
import CloudKit

/// Thrown when CloudKit returns an error tied to the user's iCloud account
/// itself rather than the request. Parallel to `DriveAuthorizationExpiredError`
/// but no recovery path — the user has to fix iCloud in Settings.
struct CloudKitBackupError: Error {
    enum Kind {
        case accountUnavailable(CKAccountStatus)
        case schemaMissing
        case quotaExceeded
        case networkUnavailable
        case underlying(Error)
    }
    let kind: Kind
    let op: String
}

/// CloudKit-backed equivalent of `DriveBackupService`. Each backup is one
/// `CKRecord` of type `WispBackup` in the user's iCloud private database
/// for the container `iCloud.barrydeen.wisp`. The record's name is an
/// opaque UUID (matches Google's `wisp_bk_<uuid>.bin` filename convention),
/// so CloudKit cannot infer the user's npub from the record metadata —
/// the npub is recovered only by decrypting `payload` with the PIN-derived
/// key.
///
/// Key behavioural difference vs `DriveBackupService`: CloudKit's modern
/// `database.records(matching:)` returns the full record (including
/// `payload`) in a single round-trip, so `BackupFile` carries the payload
/// inline. `downloadBackup(recordID:)` is kept as a no-op fast-path
/// returning the cached payload, for symmetry with the Drive API.
struct CloudKitBackupService {
    struct BackupFile: Equatable {
        let recordID: CKRecord.ID
        let payload: String
    }

    static let recordType = "WispBackup"
    static let payloadKey = "payload"
    static let createdAtKey = "createdAt"

    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: AppleAuthConfig.containerIdentifier)) {
        self.container = container
    }

    private var database: CKDatabase { container.privateCloudDatabase }

    func listBackups() async throws -> [BackupFile] {
        try await ensureAccountAvailable(op: "list")

        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Self.createdAtKey, ascending: false)]

        do {
            let (matchResults, _) = try await database.records(matching: query, resultsLimit: 100)
            var files: [BackupFile] = []
            files.reserveCapacity(matchResults.count)
            for (recordID, recordResult) in matchResults {
                if case .success(let record) = recordResult,
                   let payload = record[Self.payloadKey] as? String {
                    files.append(BackupFile(recordID: recordID, payload: payload))
                }
            }
            return files
        } catch let ckErr as CKError {
            // First-run schema isn't deployed yet, or `recordName` isn't
            // marked Queryable in the dashboard. Treat both as "no
            // backups" so the brand-new-user flow proceeds to PIN setup;
            // the first upload will auto-create the schema in the
            // development environment.
            if ckErr.code == .unknownItem || ckErr.code == .invalidArguments {
                throw CloudKitBackupError(kind: .schemaMissing, op: "list")
            }
            throw map(ckErr, op: "list")
        }
    }

    /// No-op convenience that mirrors `DriveBackupService.downloadBackup`.
    /// CloudKit hands us the payload in the list call, so we never
    /// actually need a second fetch — but keeping this method around lets
    /// the view-model code stay shape-symmetric with the Google version.
    func downloadBackup(recordID: CKRecord.ID, cachedPayload: String) async throws -> String {
        return cachedPayload
    }

    /// Creates a new record with a fresh UUID name. Each call writes a
    /// distinct record — no replace path, matching the Drive convention
    /// (sidesteps the delete-then-upload race).
    func uploadBackup(payload: String) async throws {
        try await ensureAccountAvailable(op: "upload")
        let recordID = CKRecord.ID(recordName: UUID().uuidString.lowercased())
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Self.payloadKey] = payload as CKRecordValue
        record[Self.createdAtKey] = Date() as CKRecordValue

        do {
            _ = try await database.save(record)
        } catch let ckErr as CKError {
            throw map(ckErr, op: "upload")
        }
    }

    func deleteBackup(recordID: CKRecord.ID) async throws {
        try await ensureAccountAvailable(op: "delete")
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let ckErr as CKError {
            throw map(ckErr, op: "delete")
        }
    }

    private func ensureAccountAvailable(op: String) async throws {
        let status = await AppleAuthConfig.refreshAccountStatus()
        guard status == .available else {
            throw CloudKitBackupError(kind: .accountUnavailable(status), op: op)
        }
    }

    private func map(_ err: CKError, op: String) -> CloudKitBackupError {
        let kind: CloudKitBackupError.Kind
        switch err.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy:
            kind = .networkUnavailable
        case .notAuthenticated:
            kind = .accountUnavailable(.noAccount)
        case .quotaExceeded:
            kind = .quotaExceeded
        case .unknownItem, .invalidArguments:
            kind = .schemaMissing
        default:
            kind = .underlying(err)
        }
        return CloudKitBackupError(kind: kind, op: op)
    }
}
