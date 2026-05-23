import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    enum ColorSchemePreference: String, CaseIterable {
        case system, light, dark
    }

    enum MediaLayoutStyle: String, CaseIterable {
        /// 2+ media items in a post render as a horizontal gallery (default).
        case grid
        /// 2+ media items render as a vertical stack — the original behaviour.
        case stack
    }

    enum ZapIconStyle: String, CaseIterable {
        case bolt
        case bitcoin
    }

    private struct Keys {
        static let largeText = "wisp_settings_large_text"
        static let themeName = "wisp_settings_theme_name"
        static let colorScheme = "wisp_settings_color_scheme"
        static let accentColorARGB = "wisp_settings_accent_color_argb"
        static let autoLoadMedia = "wisp_settings_auto_load_media"
        static let videoAutoplay = "wisp_settings_video_autoplay"
        static let animateAvatars = "wisp_settings_animate_avatars"
        static let mediaLayoutStyle = "wisp_settings_media_layout_style"
        static let clientTagEnabled = "wisp_settings_client_tag_enabled"
        static let fiatModeEnabled = "wisp_settings_fiat_mode_enabled"
        static let fiatCurrency = "wisp_settings_fiat_currency"
        static let notificationSoundsEnabled = "wisp_settings_notification_sounds_enabled"
        static let postUndoTimerEnabled = "wisp_settings_post_undo_timer_enabled"
        static let postUndoTimerSeconds = "wisp_settings_post_undo_timer_seconds"
        static let postUndoTimerForReplies = "wisp_settings_post_undo_timer_for_replies"
        static let autoApproveRelayAuth = "wisp_settings_auto_approve_relay_auth"
        static let zapIconStyle = "wisp_settings_zap_icon_style"
        static let videoLoop = "wisp_settings_video_loop"
        static let syncSettingsToRelays = "wisp_settings_sync_to_relays"
    }

    /// Allowed durations for the post-undo countdown. Picker shows these as
    /// the granularity for the slider/segmented control in InterfaceSettings.
    static let postUndoTimerOptions: [Int] = [5, 10, 15, 20, 30]

    private static let defaultAccentARGB: Int = 0xFFFF9800

    var largeText: Bool {
        didSet {
            UserDefaults.standard.set(largeText, forKey: Keys.largeText)
            scheduleSettingsSync()
        }
    }
    var themeName: String {
        didSet {
            UserDefaults.standard.set(themeName, forKey: Keys.themeName)
            scheduleSettingsSync()
        }
    }
    var colorScheme: ColorSchemePreference {
        didSet {
            UserDefaults.standard.set(colorScheme.rawValue, forKey: Keys.colorScheme)
            scheduleSettingsSync()
        }
    }
    var accentColorARGB: Int {
        didSet {
            UserDefaults.standard.set(accentColorARGB, forKey: Keys.accentColorARGB)
            scheduleSettingsSync()
        }
    }
    var autoLoadMedia: Bool {
        didSet {
            UserDefaults.standard.set(autoLoadMedia, forKey: Keys.autoLoadMedia)
            scheduleSettingsSync()
        }
    }
    var videoAutoplay: Bool {
        didSet {
            UserDefaults.standard.set(videoAutoplay, forKey: Keys.videoAutoplay)
            scheduleSettingsSync()
        }
    }
    var animateAvatars: Bool {
        didSet {
            UserDefaults.standard.set(animateAvatars, forKey: Keys.animateAvatars)
            scheduleSettingsSync()
        }
    }
    var mediaLayoutStyle: MediaLayoutStyle {
        didSet {
            UserDefaults.standard.set(mediaLayoutStyle.rawValue, forKey: Keys.mediaLayoutStyle)
            scheduleSettingsSync()
        }
    }
    var clientTagEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clientTagEnabled, forKey: Keys.clientTagEnabled)
            scheduleSettingsSync()
        }
    }
    var fiatModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(fiatModeEnabled, forKey: Keys.fiatModeEnabled)
            scheduleSettingsSync()
        }
    }
    var fiatCurrency: String {
        didSet {
            UserDefaults.standard.set(fiatCurrency, forKey: Keys.fiatCurrency)
            scheduleSettingsSync()
        }
    }
    // Out of scope for NIP-78 cross-device sync per the settings-sync
    // contract — notification sounds are device-local (different ringers
    // / Do Not Disturb states on each device shouldn't be overridden by
    // sync).
    var notificationSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationSoundsEnabled, forKey: Keys.notificationSoundsEnabled) }
    }
    /// When true, publishing a top-level post (and optionally replies — see
    /// `postUndoTimerForReplies`) waits `postUndoTimerSeconds` before sending,
    /// giving the user a chance to cancel.
    var postUndoTimerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(postUndoTimerEnabled, forKey: Keys.postUndoTimerEnabled)
            scheduleSettingsSync()
        }
    }
    var postUndoTimerSeconds: Int {
        didSet {
            UserDefaults.standard.set(postUndoTimerSeconds, forKey: Keys.postUndoTimerSeconds)
            scheduleSettingsSync()
        }
    }
    /// When false, replies skip the undo countdown and publish immediately —
    /// the default. Top-level posts still respect `postUndoTimerEnabled`.
    var postUndoTimerForReplies: Bool {
        didSet {
            UserDefaults.standard.set(postUndoTimerForReplies, forKey: Keys.postUndoTimerForReplies)
            scheduleSettingsSync()
        }
    }
    /// When true (default), AUTH challenges from relays are signed and sent automatically
    /// without prompting. When false, each relay must be individually approved in relay settings.
    // Out of scope for NIP-78 cross-device sync — auto-AUTH posture is
    // device-local (a device on an untrusted network may want stricter
    // per-relay prompts than another).
    var autoApproveRelayAuth: Bool {
        didSet { UserDefaults.standard.set(autoApproveRelayAuth, forKey: Keys.autoApproveRelayAuth) }
    }
    var zapIconStyle: ZapIconStyle {
        didSet {
            UserDefaults.standard.set(zapIconStyle.rawValue, forKey: Keys.zapIconStyle)
            scheduleSettingsSync()
        }
    }
    // Out of scope for NIP-78 cross-device sync — video loop is a small
    // device-local UX pref that doesn't merit relay round-trips.
    var videoLoop: Bool {
        didSet { UserDefaults.standard.set(videoLoop, forKey: Keys.videoLoop) }
    }
    /// Master toggle for cross-device sync of UI preferences via NIP-78.
    /// When off, mutations no longer schedule a relay publish and the
    /// app skips the on-launch restore. Defaults to on — privacy-aware
    /// users can opt out in Interface settings.
    var syncSettingsToRelays: Bool {
        didSet { UserDefaults.standard.set(syncSettingsToRelays, forKey: Keys.syncSettingsToRelays) }
    }

    /// Suppresses the debounced relay publish while `applyRestored` is
    /// writing into the same properties whose didSets would otherwise
    /// re-trigger sync. Without it, a restore feedback-loops into a
    /// republish of the values we just received.
    @ObservationIgnored private var isApplyingRestoredPayload = false

    /// Debounced publish task. Coalesces a burst of mutations (e.g. the
    /// user fiddles with a slider) into a single relay write.
    @ObservationIgnored private var settingsSyncTask: Task<Void, Never>?

    /// Debounce window for the relay publish. 4s comfortably outlasts a
    /// typical interactive adjustment session (toggling a few switches,
    /// dragging a slider to settle) while keeping the latency from
    /// settle → published small.
    private static let settingsSyncDebounceSeconds: UInt64 = 4

    private init() {
        let defaults = UserDefaults.standard
        self.largeText = defaults.object(forKey: Keys.largeText) as? Bool ?? false
        self.themeName = defaults.string(forKey: Keys.themeName) ?? "custom"
        let csRaw = defaults.string(forKey: Keys.colorScheme) ?? ColorSchemePreference.dark.rawValue
        self.colorScheme = ColorSchemePreference(rawValue: csRaw) ?? .dark
        self.accentColorARGB = defaults.object(forKey: Keys.accentColorARGB) as? Int ?? Self.defaultAccentARGB
        self.autoLoadMedia = defaults.object(forKey: Keys.autoLoadMedia) as? Bool ?? true
        self.videoAutoplay = defaults.object(forKey: Keys.videoAutoplay) as? Bool ?? true
        self.animateAvatars = defaults.object(forKey: Keys.animateAvatars) as? Bool ?? true
        let layoutRaw = defaults.string(forKey: Keys.mediaLayoutStyle) ?? MediaLayoutStyle.grid.rawValue
        self.mediaLayoutStyle = MediaLayoutStyle(rawValue: layoutRaw) ?? .grid
        self.clientTagEnabled = defaults.object(forKey: Keys.clientTagEnabled) as? Bool ?? true
        self.fiatModeEnabled = defaults.object(forKey: Keys.fiatModeEnabled) as? Bool ?? false
        self.fiatCurrency = defaults.string(forKey: Keys.fiatCurrency) ?? "USD"
        self.notificationSoundsEnabled = defaults.object(forKey: Keys.notificationSoundsEnabled) as? Bool ?? true
        self.postUndoTimerEnabled = defaults.object(forKey: Keys.postUndoTimerEnabled) as? Bool ?? true
        let storedSeconds = defaults.object(forKey: Keys.postUndoTimerSeconds) as? Int ?? 10
        self.postUndoTimerSeconds = Self.postUndoTimerOptions.contains(storedSeconds) ? storedSeconds : 10
        self.postUndoTimerForReplies = defaults.object(forKey: Keys.postUndoTimerForReplies) as? Bool ?? false
        self.autoApproveRelayAuth = defaults.object(forKey: Keys.autoApproveRelayAuth) as? Bool ?? true
        let zapRaw = defaults.string(forKey: Keys.zapIconStyle) ?? ZapIconStyle.bitcoin.rawValue
        self.zapIconStyle = ZapIconStyle(rawValue: zapRaw) ?? .bitcoin
        self.videoLoop = defaults.object(forKey: Keys.videoLoop) as? Bool ?? true
        self.syncSettingsToRelays = defaults.object(forKey: Keys.syncSettingsToRelays) as? Bool ?? true
    }

    // MARK: - NIP-78 cross-device sync

    /// Build a payload snapshot from the current setting values for
    /// publication via `Nip78AppSettings.createPublishEvent`. Only the
    /// in-scope Interface-screen preferences are included; out-of-scope
    /// fields (notification sounds, relay auto-auth, video loop) stay
    /// device-local by design.
    func snapshotForBackup() -> Nip78AppSettings.AppSettingsPayload {
        Nip78AppSettings.AppSettingsPayload(
            version: 1,
            largeText: largeText,
            colorScheme: colorScheme.rawValue,
            themeName: themeName,
            accentColorARGB: accentColorARGB,
            autoLoadMedia: autoLoadMedia,
            videoAutoplay: videoAutoplay,
            animateAvatars: animateAvatars,
            mediaLayoutStyle: mediaLayoutStyle.rawValue,
            clientTagEnabled: clientTagEnabled,
            postUndoTimerEnabled: postUndoTimerEnabled,
            postUndoTimerSeconds: postUndoTimerSeconds,
            postUndoTimerForReplies: postUndoTimerForReplies,
            fiatModeEnabled: fiatModeEnabled,
            fiatCurrency: fiatCurrency,
            zapIconStyle: zapIconStyle.rawValue
        )
    }

    /// Apply a restored payload onto the live settings. Each field that
    /// came through the wire overwrites the local value; missing fields
    /// keep the local default. The suppression flag prevents the didSet
    /// chain from echoing this restore back out as a fresh publish.
    func applyRestored(_ payload: Nip78AppSettings.AppSettingsPayload) {
        isApplyingRestoredPayload = true
        defer { isApplyingRestoredPayload = false }

        if let v = payload.largeText { self.largeText = v }
        if let raw = payload.colorScheme,
           let cs = ColorSchemePreference(rawValue: raw) { self.colorScheme = cs }
        if let v = payload.themeName { self.themeName = v }
        if let v = payload.accentColorARGB { self.accentColorARGB = v }

        if let v = payload.autoLoadMedia { self.autoLoadMedia = v }
        if let v = payload.videoAutoplay { self.videoAutoplay = v }
        if let v = payload.animateAvatars { self.animateAvatars = v }
        if let raw = payload.mediaLayoutStyle,
           let layout = MediaLayoutStyle(rawValue: raw) { self.mediaLayoutStyle = layout }

        if let v = payload.clientTagEnabled { self.clientTagEnabled = v }
        if let v = payload.postUndoTimerEnabled { self.postUndoTimerEnabled = v }
        if let v = payload.postUndoTimerSeconds,
           Self.postUndoTimerOptions.contains(v) { self.postUndoTimerSeconds = v }
        if let v = payload.postUndoTimerForReplies { self.postUndoTimerForReplies = v }

        if let v = payload.fiatModeEnabled { self.fiatModeEnabled = v }
        if let v = payload.fiatCurrency { self.fiatCurrency = v }
        if let raw = payload.zapIconStyle,
           let style = ZapIconStyle(rawValue: raw) { self.zapIconStyle = style }
    }

    /// Reset every synced field to its default value. Called from the
    /// logout / account-switch paths so the prior account's preferences
    /// don't bleed into the splash / login screen or into the next
    /// account's session. The suppression flag prevents the didSet
    /// chain from publishing a "defaults" payload back to relays —
    /// resets are a local operation only.
    ///
    /// Out-of-scope fields (notificationSoundsEnabled,
    /// autoApproveRelayAuth, videoLoop) stay untouched: they're
    /// device-local already and aren't tied to the account.
    func resetSyncedSettingsToDefaults() {
        isApplyingRestoredPayload = true
        defer { isApplyingRestoredPayload = false }

        largeText = false
        themeName = "custom"
        colorScheme = .dark
        accentColorARGB = Self.defaultAccentARGB

        autoLoadMedia = true
        videoAutoplay = true
        animateAvatars = true
        mediaLayoutStyle = .grid

        clientTagEnabled = true
        postUndoTimerEnabled = true
        postUndoTimerSeconds = 10
        postUndoTimerForReplies = false

        fiatModeEnabled = false
        fiatCurrency = "USD"
        zapIconStyle = .bitcoin

        // Cancel any pending publish that was queued before the reset
        // arrived. Without this, a debounced publish from the prior
        // account could fire after the keypair is gone and post the
        // defaults payload to an unrelated relay.
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
    }

    /// Debounced publish of the current settings snapshot to the active
    /// keypair's outbox relays. Cancels any in-flight publish task so
    /// the most recent change wins. Becomes a no-op when sync is off,
    /// when a restore is in progress, or when no signing keypair is
    /// available.
    func scheduleSettingsSync() {
        guard syncSettingsToRelays, !isApplyingRestoredPayload else { return }
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.settingsSyncDebounceSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.publishSettingsNow()
        }
    }

    /// Immediate (non-debounced) publish. Bypasses the debounce timer —
    /// the InterfaceSettings "Sync now" affordance uses this, and so does
    /// any test path. Still gated on the `syncSettingsToRelays` toggle.
    func publishSettingsNow() async {
        guard syncSettingsToRelays else { return }
        guard let keypair = NostrKey.load(), !keypair.isWatchOnly else { return }

        do {
            let event = try await Nip78AppSettings.createPublishEvent(
                keypair: keypair,
                payload: snapshotForBackup()
            )
            let relays = Self.syncRelays(for: keypair.pubkey)
            guard !relays.isEmpty else { return }
            _ = await RelayPool.publish(event: event, to: relays, timeout: 6)
        } catch {
            // Logged inside the Signer path; swallow here so a transient
            // signer failure doesn't bubble up to the settings UI.
        }
    }

    /// Tracks the last pubkey we've handled an account-change event
    /// for. The first transition (`nil` → first signed-in account on
    /// app launch) is left to `restoreOnLaunchIfNeeded` — running the
    /// reset path here too triggers a rebuild loop because writing
    /// defaults to the synced fields changes `RootContainer`'s `.id`,
    /// which destroys `ContentView`, which `.onAppear`s and re-loads
    /// the saved keypair, which fires `.onChange` again, ad
    /// infinitum.
    @ObservationIgnored private var lastHandledAccountPubkey: String?
    @ObservationIgnored private var hasHandledFirstAccount = false

    /// Called from ContentView when the active account changes
    /// (sign-in, sign-out, mid-session switch). With sync enabled,
    /// wipes the prior account's synced fields and pulls the new
    /// account's snapshot from relays so the UI flips immediately to
    /// the new account's preferences instead of carrying the prior
    /// account's theme into the splash / next session.
    ///
    /// First-bind-ever (the initial sign-in on app start) is a no-op
    /// — `restoreOnLaunchIfNeeded` already covers that case under its
    /// per-pubkey flag, and bypassing it here both burns relay
    /// traffic and pulls down the rebuild-loop described in the
    /// `lastHandledAccountPubkey` doc.
    ///
    /// With sync disabled, this is a no-op — the user has opted out
    /// of cross-device sync and presumably wants device-stable
    /// settings across account changes too. They can re-enable sync
    /// and tap Restore manually if they change their mind.
    func handleActiveAccountChange() async {
        let currentPubkey = NostrKey.load()?.pubkey
        if currentPubkey == lastHandledAccountPubkey { return }
        let isFirstHandle = !hasHandledFirstAccount
        hasHandledFirstAccount = true

        if isFirstHandle {
            // First account ever on this app run — restoreOnLaunchIfNeeded
            // handles it. Mark as handled so subsequent transitions know
            // we've seen this pubkey.
            lastHandledAccountPubkey = currentPubkey
            return
        }

        guard syncSettingsToRelays else {
            lastHandledAccountPubkey = currentPubkey
            return
        }

        // Defer reset + restore until onboarding finishes for the new
        // account. Running the property writes mid-onboarding triggers
        // a RootContainer .id change that remounts OnboardingView and
        // restarts its welcome-spinner .task — visible to the user as
        // the avatar spinner firing a second time. ContentView re-fires
        // this method from OnboardingView's onComplete so the deferred
        // work happens once the user lands in .main.
        if let pk = currentPubkey, !NostrKey.isOnboardingComplete(pubkey: pk) {
            return
        }

        lastHandledAccountPubkey = currentPubkey
        resetSyncedSettingsToDefaults()
        if currentPubkey != nil {
            await restoreFromRelays()
        }
    }

    /// First-time-per-account restore. Called from the root view at
    /// launch. Once a pubkey has been restored on this device the flag
    /// persists in UserDefaults so subsequent launches skip the network
    /// hit — the device's local settings then become the source of
    /// truth and changes flow back out via the debounced publish path.
    /// The user can still trigger a manual re-restore from the
    /// Interface settings screen.
    func restoreOnLaunchIfNeeded() async {
        guard syncSettingsToRelays else { return }
        guard let keypair = NostrKey.load(), !keypair.isWatchOnly else { return }
        // Same reasoning as the defer in handleActiveAccountChange —
        // an applyRestored mid-onboarding would write to AppSettings
        // properties and trigger a RootContainer .id change that
        // remounts OnboardingView. Wait until the user is past
        // onboarding; ContentView re-fires this path from
        // OnboardingView's onComplete via handleActiveAccountChange.
        guard NostrKey.isOnboardingComplete(pubkey: keypair.pubkey) else { return }
        let flagKey = "wisp_settings_restored_\(keypair.pubkey)"
        if UserDefaults.standard.bool(forKey: flagKey) { return }
        await restoreFromRelays()
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// Fetch the user's latest NIP-78 settings event from relays and
    /// apply it. Safe to call at every app launch — applyRestored is
    /// idempotent and the suppression flag prevents a re-publish.
    func restoreFromRelays() async {
        guard syncSettingsToRelays else { return }
        guard let keypair = NostrKey.load(), !keypair.isWatchOnly else { return }

        let relays = Self.syncRelays(for: keypair.pubkey)
        guard !relays.isEmpty else { return }

        let events = await RelayPool.query(
            relays: relays,
            filter: Nip78AppSettings.filter(pubkey: keypair.pubkey),
            timeout: 8,
            waitForAllRelays: false
        )
        let matching = events.filter { Nip78AppSettings.matches($0) }
        guard let latest = matching.max(by: { $0.createdAt < $1.createdAt }) else { return }
        guard let payload = await Nip78AppSettings.decryptPayload(keypair: keypair, event: latest) else { return }
        applyRestored(payload)
    }

    /// Outbox-like relay selection for settings publishes / reads. Uses
    /// the user's top-scored relays when known; falls back to a small
    /// set of public relays for first-time users / brand-new installs
    /// where the scoreboard hasn't been populated yet.
    private static func syncRelays(for pubkey: String) -> [String] {
        if let board = RelayScoreBoard.load(pubkey: pubkey) {
            let top = board.scoredRelays.prefix(8).map(\.url)
            if !top.isEmpty { return top }
        }
        return [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol"
        ]
    }

    /// SF Symbol name for the zap icon. Only valid when `fiatModeEnabled` is false.
    /// Use `zapImage` for rendering — it handles the fiat coin stack automatically.
    var zapSymbolName: String {
        zapIconStyle == .bitcoin ? "bitcoinsign" : "bolt.fill"
    }

    /// The correct zap icon for the current mode. Fiat mode renders the coin stack asset;
    /// otherwise uses the user's bolt / bitcoin SF Symbol preference.
    var zapImage: Image {
        if fiatModeEnabled { return Image("CoinStack") }
        return Image(systemName: zapSymbolName)
    }

    var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accentColor: Color {
        Color(argb: accentColorARGB)
    }
}

// `nonisolated` — these initializers and `hex(_:)` are pure value transforms
// (Int → Color), used at module-load time by `Themes` and from any actor.
nonisolated extension Color {
    init(argb: Int) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a == 0 ? 1 : a)
    }

    init(rgb: Int) {
        self.init(argb: 0xFF000000 | (rgb & 0x00FFFFFF))
    }

    static func hex(_ argb: UInt32) -> Color {
        Color(argb: Int(bitPattern: UInt(argb)))
    }
}
