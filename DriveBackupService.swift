import Foundation

/// Thrown when Drive returns 401 on a request authenticated with the supplied
/// access token. Caller must obtain a fresh token (via
/// `GoogleSignInManager.refreshDriveAccessToken`) and retry — most commonly
/// because the user revoked Wisp's authorization from their Google account
/// settings.
struct DriveAuthorizationExpiredError: Error {
    let staleToken: String
    let op: String
}

/// Generic HTTP error surface for non-401 failures.
struct DriveHttpError: Error {
    let op: String
    let status: Int
    let body: String
}

/// Minimal Drive REST v3 client targeted at the user's appDataFolder.
///
/// Filenames are opaque (`wisp_bk_<uuid>.bin`) so Drive cannot see the user's
/// npub — that link would otherwise let anyone with Google account access tie
/// the Nostr identity to the Google identity. The npub is recovered by
/// decrypting the file with the user's PIN-derived key.
struct DriveBackupService {
    struct BackupFile: Equatable {
        let fileId: String
        let name: String
    }

    private static let appDataFolder = "appDataFolder"
    private static let backupPrefix = "wisp_bk_"
    private static let backupSuffix = ".bin"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listBackups(accessToken: String) async throws -> [BackupFile] {
        let nameQuery = "name contains '\(Self.backupPrefix)'"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: nameQuery),
            URLQueryItem(name: "fields", value: "files(id,name,modifiedTime)"),
            URLQueryItem(name: "pageSize", value: "100"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try throwIfExpired(accessToken: accessToken, response: response, op: "list", body: data)
        try throwIfHttpError(response: response, body: data, op: "list")

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]] else {
            return []
        }
        return files.compactMap { file -> BackupFile? in
            guard let id = file["id"] as? String,
                  let name = file["name"] as? String,
                  name.hasPrefix(Self.backupPrefix),
                  name.hasSuffix(Self.backupSuffix) else { return nil }
            return BackupFile(fileId: id, name: name)
        }
    }

    func downloadBackup(accessToken: String, fileId: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try throwIfExpired(accessToken: accessToken, response: response, op: "download", body: data)
        try throwIfHttpError(response: response, body: data, op: "download")

        guard let text = String(data: data, encoding: .utf8) else {
            throw DriveHttpError(op: "download", status: -1, body: "non-UTF8 body")
        }
        return text
    }

    /// Creates a new backup file with a fresh random UUID filename. Each call
    /// creates a distinct file — there is no replace path, which sidesteps
    /// the delete-then-upload race that an in-place update would introduce
    /// (this matches the Android implementation exactly).
    func uploadBackup(accessToken: String, payload: String) async throws {
        let filename = "\(Self.backupPrefix)\(UUID().uuidString.lowercased())\(Self.backupSuffix)"
        let boundary = "wisp-\(UUID().uuidString.lowercased())"
        let crlf = "\r\n"
        let metadata = "{\"name\":\"\(filename)\",\"parents\":[\"\(Self.appDataFolder)\"]}"

        var body = ""
        body += "--\(boundary)\(crlf)"
        body += "Content-Type: application/json; charset=UTF-8\(crlf)\(crlf)"
        body += "\(metadata)\(crlf)"
        body += "--\(boundary)\(crlf)"
        body += "Content-Type: application/octet-stream\(crlf)\(crlf)"
        body += "\(payload)\(crlf)"
        body += "--\(boundary)--\(crlf)"

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try throwIfExpired(accessToken: accessToken, response: response, op: "upload", body: data)
        try throwIfHttpError(response: response, body: data, op: "upload")
    }

    func deleteBackup(accessToken: String, fileId: String) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private func throwIfExpired(accessToken: String, response: URLResponse, op: String, body: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else { return }
        throw DriveAuthorizationExpiredError(staleToken: accessToken, op: op)
    }

    private func throwIfHttpError(response: URLResponse, body: Data, op: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        let bodyText = String(data: body, encoding: .utf8) ?? "<binary \(body.count)B>"
        throw DriveHttpError(op: op, status: http.statusCode, body: bodyText)
    }
}
