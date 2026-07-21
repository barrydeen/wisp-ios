import Foundation
import Observation
import NaturalLanguage

/// Translation lifecycle for a single note. Mirrors Android wisp's
/// `TranslationStatus` (TranslationRepository.kt), plus `skippedNotInstalled`
/// — an iOS-only terminal state recorded when auto-translate skips a note
/// because the language model isn't downloaded (Android's ML Kit downloads
/// silently; Apple's framework would pop a system consent sheet mid-scroll).
enum TranslationStatus {
    case idle
    case identifyingLanguage
    case downloadingModel
    case translating
    case done
    case error
    case sameLanguage
    case skippedNotInstalled
}

/// Per-note translation state. Mirrors Android wisp's `TranslationState`.
struct TranslationState {
    var status: TranslationStatus = .idle
    var translatedText: String = ""
    /// Source language display name, e.g. "Spanish".
    var sourceLanguage: String = ""
    /// Target (device) language display name, e.g. "English".
    var targetLanguage: String = ""
    var errorMessage: String = ""
}

/// Per-event observable box. Reading `state` from a card creates a SwiftUI
/// tracking dependency on this box only, not on the repository's whole dict —
/// same pattern as `EngagementBox`, so one note finishing a translation
/// doesn't recompose every visible card.
@Observable
@MainActor
final class TranslationBox {
    var state = TranslationState()
}

/// Ephemeral per-note translation state, ported from Android wisp's
/// `TranslationRepository`. Android uses ML Kit language-ID + translate;
/// iOS uses NaturalLanguage for detection and the Translation framework
/// for the actual translation. Because `TranslationSession` can only be
/// obtained through SwiftUI's `.translationTask` modifier (it is bound to
/// the hosting view's lifecycle), this repository holds *state only* —
/// detection, the same-language short-circuit, and the status machine.
/// The session call itself lives in `PostCardView`'s `.translationTask`
/// closure, which reports progress back here. Android's `version`
/// StateFlow is replaced by `@Observable` change tracking on the boxes.
///
/// Nothing is persisted; the original note content is never modified.
@Observable
@MainActor
final class TranslationRepository {
    static let shared = TranslationRepository()
    private init() {}

    /// Keyed by (repost-resolved) event id. `@ObservationIgnored` so dict
    /// mutations never trigger observers of the repository itself — only the
    /// mutated box notifies its one card.
    @ObservationIgnored private var boxes: [String: TranslationBox] = [:]

    func box(for eventId: String) -> TranslationBox {
        if let b = boxes[eventId] { return b }
        let b = TranslationBox()
        boxes[eventId] = b
        return b
    }

    func state(for eventId: String) -> TranslationState {
        box(for: eventId).state
    }

    /// Target language for translations — the device language, matching
    /// Android's `Locale.getDefault().language`.
    var targetLanguage: Locale.Language { Locale.current.language }

    /// Detect the note's language and short-circuit when it already matches
    /// the device language (Android's IDENTIFYING_LANGUAGE → SAME_LANGUAGE
    /// path). Returns the source language to translate from, or nil when no
    /// translation session should be created (same language / undetectable —
    /// the terminal state is already recorded in the box).
    func beginTranslation(eventId: String, content: String) -> Locale.Language? {
        // Idempotent like Android: only (re-)run from idle, error, or an
        // auto-translate skip (a manual tap is the consent path that
        // downloads the model).
        let current = box(for: eventId).state.status
        guard current == .idle || current == .error || current == .skippedNotInstalled else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(content)
        guard let detected = recognizer.dominantLanguage else {
            // Android: ML Kit returns "und" → "Could not detect language".
            box(for: eventId).state = TranslationState(
                status: .error,
                errorMessage: "Could not detect language"
            )
            return nil
        }

        let source = Locale.Language(identifier: detected.rawValue)
        // Compare base language codes, not raw identifiers — NLLanguage can
        // yield script-tagged codes like "zh-Hans" while the device locale
        // reports plain "zh".
        if source.languageCode == Locale.current.language.languageCode {
            box(for: eventId).state = TranslationState(
                status: .sameLanguage,
                sourceLanguage: displayName(for: detected.rawValue),
                targetLanguage: deviceLanguageDisplayName
            )
            return nil
        }

        box(for: eventId).state = TranslationState(
            status: .identifyingLanguage,
            sourceLanguage: displayName(for: detected.rawValue),
            targetLanguage: deviceLanguageDisplayName
        )
        return source
    }

    /// In-flight transitions only — a `.translationTask` closure re-running
    /// for a card whose translation already completed must not clobber the
    /// terminal state back to a spinner.
    func markDownloadingModel(eventId: String) {
        transitionInFlight(eventId: eventId, to: .downloadingModel)
    }

    func markTranslating(eventId: String) {
        transitionInFlight(eventId: eventId, to: .translating)
    }

    private func transitionInFlight(eventId: String, to status: TranslationStatus) {
        let b = box(for: eventId)
        guard b.state.status == .identifyingLanguage
            || b.state.status == .downloadingModel
            || b.state.status == .translating else { return }
        b.state.status = status
    }

    func finish(eventId: String, translatedText: String) {
        let b = box(for: eventId)
        b.state.status = .done
        b.state.translatedText = translatedText
    }

    func fail(eventId: String, message: String) {
        let b = box(for: eventId)
        b.state.status = .error
        b.state.errorMessage = message
    }

    /// Auto-translate found the language pair supported but its model not
    /// downloaded. Terminal so re-appearing cards don't re-run detection;
    /// the menu still offers "Translate" (the manual consent path).
    func markSkippedNotInstalled(eventId: String) {
        box(for: eventId).state.status = .skippedNotInstalled
    }

    /// Clears a note back to idle, e.g. when its view-bound session is torn
    /// down mid-flight (row recycled / navigation) — a stuck in-flight state
    /// would leave a permanent spinner with the menu item disabled.
    func resetToIdle(eventId: String) {
        box(for: eventId).state = TranslationState()
    }

    private var deviceLanguageDisplayName: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return displayName(for: code)
    }

    private func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
