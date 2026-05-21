import Foundation
import UIKit

/// Orchestrates the "Continue with Google" flow:
///   1. Sign in via `GoogleSignInManager` → keep the JWT `sub` claim around.
///   2. List backups in the user's appData folder. Filenames are opaque
///      (`wisp_bk_<uuid>.bin`); the npub is recovered by decrypting.
///   3. Branch on what we find:
///        - Files exist → prompt for the user's PIN, try to decrypt each file,
///          and show the recovered accounts in the chooser. Files that fail
///          to decrypt are treated as belonging to a different (or wrong) PIN.
///        - No files → walk the user through setting a new PIN (enter, then
///          confirm) and create their first account.
///   4. From the chooser the user can restore one of the listed accounts or
///      add another account under the same Google login (PIN already known).
@Observable
@MainActor
final class GoogleAuthViewModel {
    enum SetupStep: Equatable { case enter, confirm }

    struct BackupSummary: Identifiable, Equatable {
        let fileId: String
        let npub: String
        let pubkeyHex: String
        var displayName: String?
        var picture: String?
        var id: String { npub }
    }

    enum State {
        case idle
        case signingIn
        case checkingDrive
        case enterPinForRestore(attemptFailed: Bool)
        case setupPin(step: SetupStep, mismatch: Bool)
        case choose(backups: [BackupSummary])
        case working
        case done(isNewAccount: Bool, keypair: Keypair)
        case error(message: String)
    }

    private(set) var state: State = .idle

    private let signInManager = GoogleSignInManager()
    private let driveService = DriveBackupService()

    private var pendingSub: String?
    private var pendingAccessToken: String?
    private var pendingBackupKey: Data?
    private var pendingFiles: [DriveBackupService.BackupFile] = []
    private var pendingSetupFirstPin: String?
    private var profileFetchTask: Task<Void, Never>?

    // MARK: - Public entry points

    func beginSignIn(presenting: UIViewController) {
        switch state {
        case .idle, .error: break
        default: return
        }
        state = .signingIn
        Task { @MainActor in
            do {
                let result = try await signInManager.signIn(presenting: presenting)
                pendingSub = result.sub
                pendingAccessToken = result.accessToken

                state = .checkingDrive
                let files = try await listBackupsWithRefresh()
                pendingFiles = files

                state = files.isEmpty
                    ? .setupPin(step: .enter, mismatch: false)
                    : .enterPinForRestore(attemptFailed: false)
            } catch let e as GoogleSignInManager.SignInError {
                if case .cancelled = e {
                    // Treat cancel as a return-to-splash, not an error screen.
                    reset()
                } else {
                    state = .error(message: e.errorDescription ?? "Google sign-in failed.")
                }
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    func submitRestorePin(_ pin: String) {
        guard BackupCrypto.isValidPin(pin), let sub = pendingSub else { return }
        let files = pendingFiles
        guard !files.isEmpty else { return }
        state = .working
        Task { @MainActor in
            do {
                let key = try await deriveKeyOffMain(sub: sub, pin: pin)
                var summaries: [BackupSummary] = []
                var seen = Set<String>()
                for file in files {
                    do {
                        let payload = try await downloadWithRefresh(fileId: file.fileId)
                        let nsec = try BackupCrypto.decryptNsec(payload: payload, key32: key)
                        let pubkey = try Schnorr.xonlyPubkey(privkey32: nsec)
                        let pubkeyHex = Hex.encode(pubkey)
                        guard let npub = Nip19.npubEncode(pubkey: Array(pubkey)) else { continue }
                        if seen.contains(npub) { continue }
                        seen.insert(npub)
                        summaries.append(BackupSummary(
                            fileId: file.fileId,
                            npub: npub,
                            pubkeyHex: pubkeyHex
                        ))
                    } catch {
                        // Likely wrong PIN or an unrelated file in the folder —
                        // mirror Android: silently skip and let the empty-set
                        // check below surface "incorrect PIN".
                        continue
                    }
                }

                if summaries.isEmpty {
                    state = .enterPinForRestore(attemptFailed: true)
                    return
                }

                pendingBackupKey = key
                state = .choose(backups: summaries)
                fetchProfilesInBackground(realPubkeys: summaries.map { $0.pubkeyHex })
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    func submitSetupPinEntry(_ pin: String) {
        guard BackupCrypto.isValidPin(pin) else { return }
        pendingSetupFirstPin = pin
        state = .setupPin(step: .confirm, mismatch: false)
    }

    func submitSetupPinConfirm(_ pin: String) {
        guard BackupCrypto.isValidPin(pin) else { return }
        guard let first = pendingSetupFirstPin, first == pin else {
            pendingSetupFirstPin = nil
            state = .setupPin(step: .enter, mismatch: true)
            return
        }
        guard let sub = pendingSub else { return }
        pendingSetupFirstPin = nil
        state = .working
        Task { @MainActor in
            do {
                let key = try await deriveKeyOffMain(sub: sub, pin: pin)
                pendingBackupKey = key
                try await createAndStoreNewAccount()
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    func backToSetupEntry() {
        pendingSetupFirstPin = nil
        state = .setupPin(step: .enter, mismatch: false)
    }

    func restoreAccount(fileId: String) {
        guard let key = pendingBackupKey, let accessToken = pendingAccessToken else { return }
        state = .working
        Task { @MainActor in
            do {
                let payload = try await downloadWithToken(fileId: fileId, token: accessToken)
                let nsec = try BackupCrypto.decryptNsec(payload: payload, key32: key)
                let pubkey = try Schnorr.xonlyPubkey(privkey32: nsec)
                let pubkeyHex = Hex.encode(pubkey)
                let keypair = Keypair(privkey: Hex.encode(nsec), pubkey: pubkeyHex)
                NostrKey.save(keypair)
                NostrKey.registerInAccountList(pubkeyHex)
                state = .done(isNewAccount: false, keypair: keypair)
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    /// Called from the choose screen when the user wants to add another
    /// account to a Google login that already has backups. PIN is already
    /// known (we still have `pendingBackupKey`).
    func createAnotherAccount() {
        guard pendingBackupKey != nil else { return }
        state = .working
        Task { @MainActor in
            do {
                try await createAndStoreNewAccount()
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    func reset() {
        profileFetchTask?.cancel()
        profileFetchTask = nil
        pendingSub = nil
        pendingAccessToken = nil
        pendingBackupKey = nil
        pendingFiles = []
        pendingSetupFirstPin = nil
        state = .idle
    }

    // MARK: - Internals

    private func createAndStoreNewAccount() async throws {
        guard let key = pendingBackupKey else { throw GoogleSignInManager.SignInError.notSignedIn }
        let privkey = Schnorr.randomPrivkey()
        let pubkey = try Schnorr.xonlyPubkey(privkey32: privkey)
        let pubkeyHex = Hex.encode(pubkey)
        let payload = try BackupCrypto.encryptNsec(nsec32: privkey, key32: key)
        try await uploadWithRefresh(payload: payload)
        let keypair = Keypair(privkey: Hex.encode(privkey), pubkey: pubkeyHex)
        NostrKey.save(keypair)
        NostrKey.registerInAccountList(pubkeyHex)
        state = .done(isNewAccount: true, keypair: keypair)
    }

    private func deriveKeyOffMain(sub: String, pin: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try BackupCrypto.deriveBackupKey(sub: sub, pin: pin)
        }.value
    }

    // MARK: - Drive call wrappers with 401 refresh

    private func listBackupsWithRefresh() async throws -> [DriveBackupService.BackupFile] {
        guard let token = pendingAccessToken else { throw GoogleSignInManager.SignInError.notSignedIn }
        do {
            return try await driveService.listBackups(accessToken: token)
        } catch is DriveAuthorizationExpiredError {
            let fresh = try await refreshToken()
            return try await driveService.listBackups(accessToken: fresh)
        }
    }

    private func downloadWithRefresh(fileId: String) async throws -> String {
        guard let token = pendingAccessToken else { throw GoogleSignInManager.SignInError.notSignedIn }
        do {
            return try await driveService.downloadBackup(accessToken: token, fileId: fileId)
        } catch is DriveAuthorizationExpiredError {
            let fresh = try await refreshToken()
            return try await driveService.downloadBackup(accessToken: fresh, fileId: fileId)
        }
    }

    private func downloadWithToken(fileId: String, token: String) async throws -> String {
        do {
            return try await driveService.downloadBackup(accessToken: token, fileId: fileId)
        } catch is DriveAuthorizationExpiredError {
            let fresh = try await refreshToken()
            return try await driveService.downloadBackup(accessToken: fresh, fileId: fileId)
        }
    }

    private func uploadWithRefresh(payload: String) async throws {
        guard let token = pendingAccessToken else { throw GoogleSignInManager.SignInError.notSignedIn }
        do {
            try await driveService.uploadBackup(accessToken: token, payload: payload)
        } catch is DriveAuthorizationExpiredError {
            let fresh = try await refreshToken()
            try await driveService.uploadBackup(accessToken: fresh, payload: payload)
        }
    }

    private func refreshToken() async throws -> String {
        let fresh = try await signInManager.refreshDriveAccessToken()
        pendingAccessToken = fresh
        return fresh
    }

    // MARK: - Profile decoy fetch

    /// Pulls decoy profiles from a popular relay first, then issues one
    /// combined REQ for (real + decoys) against the profile relays. From a
    /// relay operator's perspective the real backup pubkeys are mixed in
    /// with random recent profiles, blunting the "this Google account
    /// corresponds to these npubs" linkage. UI updates filter to only the
    /// real pubkeys. Mirrors `fetchProfilesInBackground` from the Android
    /// `GoogleAuthViewModel`.
    private func fetchProfilesInBackground(realPubkeys: [String]) {
        profileFetchTask?.cancel()
        let real = Array(Set(realPubkeys))
        guard !real.isEmpty else { return }

        profileFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let decoys = await Self.fetchDecoyPubkeys(count: Self.decoyCount, timeoutMs: Self.decoyFetchTimeoutMs)
                .filter { !real.contains($0) }
            let combined = (real + decoys).shuffled()
            let realSet = Set(real)

            await Self.queryProfiles(
                relays: Self.profileRelays,
                authors: combined,
                timeoutMs: Self.profileFetchTimeoutMs
            ) { [weak self] pubkey, name, picture in
                guard let self else { return }
                guard realSet.contains(pubkey) else { return }
                guard case .choose(let backups) = self.state else { return }
                let updated = backups.map { backup -> BackupSummary in
                    guard backup.pubkeyHex == pubkey,
                          (backup.displayName == nil || backup.picture == nil) else { return backup }
                    var copy = backup
                    if copy.displayName == nil { copy.displayName = name }
                    if copy.picture == nil { copy.picture = picture }
                    return copy
                }
                self.state = .choose(backups: updated)
            }
        }
    }

    private static func fetchDecoyPubkeys(count: Int, timeoutMs: Int) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let subId = "wisp-google-decoys"
            let req = #"["REQ","\#(subId)",{"kinds":[0],"limit":\#(count)}]"#
            let url = URL(string: decoyRelay)!
            let task = URLSession.shared.webSocketTask(with: url)
            let collected = NSMutableOrderedSet()
            let resumed = NSLock()
            var didResume = false

            func resumeOnce(_ result: [String]) {
                resumed.lock()
                let shouldResume = !didResume
                if shouldResume { didResume = true }
                resumed.unlock()
                guard shouldResume else { return }
                task.send(.string(#"["CLOSE","\#(subId)"]"#)) { _ in }
                task.cancel(with: .normalClosure, reason: nil)
                cont.resume(returning: result)
            }

            func listen() {
                task.receive { msg in
                    switch msg {
                    case .success(.string(let text)):
                        if let pubkey = parseProfileEventPubkey(text) {
                            collected.add(pubkey)
                            if collected.count >= count {
                                let arr = collected.array.compactMap { $0 as? String }
                                resumeOnce(arr)
                                return
                            }
                        } else if isEose(text) {
                            let arr = collected.array.compactMap { $0 as? String }
                            resumeOnce(arr)
                            return
                        }
                        listen()
                    case .success(.data):
                        listen()
                    case .failure:
                        let arr = collected.array.compactMap { $0 as? String }
                        resumeOnce(arr)
                    @unknown default:
                        listen()
                    }
                }
            }

            task.resume()
            task.send(.string(req)) { _ in }
            listen()

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                let arr = collected.array.compactMap { $0 as? String }
                resumeOnce(arr)
            }
        }
    }

    private static func queryProfiles(
        relays: [String],
        authors: [String],
        timeoutMs: Int,
        onProfile: @MainActor @escaping (_ pubkey: String, _ name: String?, _ picture: String?) -> Void
    ) async {
        guard !authors.isEmpty else { return }
        let subId = "wisp-google-profiles"
        let authorsJson = authors.map { "\"\($0)\"" }.joined(separator: ",")
        let req = #"["REQ","\#(subId)",{"kinds":[0],"authors":[\#(authorsJson)]}]"#

        let tasks: [URLSessionWebSocketTask] = relays.compactMap { urlString in
            guard let url = URL(string: urlString) else { return nil }
            let t = URLSession.shared.webSocketTask(with: url)
            t.resume()
            t.send(.string(req)) { _ in }
            listenForProfileEvents(task: t, onProfile: onProfile)
            return t
        }

        try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)

        for t in tasks {
            t.send(.string(#"["CLOSE","\#(subId)"]"#)) { _ in }
            t.cancel(with: .normalClosure, reason: nil)
        }
    }

    private static func listenForProfileEvents(
        task: URLSessionWebSocketTask,
        onProfile: @MainActor @escaping (_ pubkey: String, _ name: String?, _ picture: String?) -> Void
    ) {
        task.receive { msg in
            switch msg {
            case .success(.string(let text)):
                if let (pubkey, name, picture) = parseKind0Event(text) {
                    Task { @MainActor in onProfile(pubkey, name, picture) }
                }
                listenForProfileEvents(task: task, onProfile: onProfile)
            case .success(.data):
                listenForProfileEvents(task: task, onProfile: onProfile)
            case .failure:
                return
            @unknown default:
                return
            }
        }
    }

    /// Returns the pubkey of any kind:0 EVENT in the relay frame, otherwise nil.
    private static func parseProfileEventPubkey(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3,
              let tag = arr[0] as? String, tag == "EVENT",
              let event = arr[2] as? [String: Any],
              let pubkey = event["pubkey"] as? String else { return nil }
        return pubkey
    }

    private static func isEose(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 1,
              let tag = arr[0] as? String else { return false }
        return tag == "EOSE"
    }

    private static func parseKind0Event(_ text: String) -> (String, String?, String?)? {
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.count >= 3,
              let tag = arr[0] as? String, tag == "EVENT",
              let event = arr[2] as? [String: Any],
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let contentData = content.data(using: .utf8),
              let profile = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            return nil
        }
        let kindAny = event["kind"]
        let kindOk: Bool = {
            if let n = kindAny as? Int { return n == 0 }
            if let n = kindAny as? NSNumber { return n.intValue == 0 }
            return false
        }()
        guard kindOk else { return nil }

        let name = (profile["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (profile["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let picture = (profile["picture"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if name == nil && picture == nil { return nil }
        return (pubkey, name, picture)
    }

    // MARK: - Constants

    private static let profileRelays = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
    ]
    private static let decoyRelay = "wss://relay.primal.net"
    private static let decoyCount = 10
    private static let decoyFetchTimeoutMs = 4_000
    private static let profileFetchTimeoutMs = 8_000
}
