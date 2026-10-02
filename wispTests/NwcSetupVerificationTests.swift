import Foundation
import Testing
@testable import wisp

/// The setup flow verifies a pasted NWC URI with one short round-trip before
/// declaring success, so a revoked or offline connection alerts within
/// seconds instead of dismissing into a silently broken dashboard. These pin
/// the user-facing wording per verification outcome.
@MainActor
struct NwcSetupVerificationTests {

    @Test func unauthorizedRefusalNamesRevocation() {
        let message = WalletStore.setupFailureMessage(for: .refused(code: "UNAUTHORIZED", message: "bad secret"))
        #expect(message.contains("revoked"))
    }

    @Test func otherRefusalCarriesWalletMessage() {
        let message = WalletStore.setupFailureMessage(for: .refused(code: "INTERNAL", message: "boom"))
        #expect(message == "The wallet rejected the request: boom.")
    }

    @Test func otherRefusalWithoutMessageShowsCode() {
        let message = WalletStore.setupFailureMessage(for: .refused(code: "QUOTA_EXCEEDED", message: nil))
        #expect(message == "The wallet rejected the request (QUOTA_EXCEEDED).")
    }

    @Test func unresponsiveExplainsSilence() {
        let message = WalletStore.setupFailureMessage(for: .unresponsive)
        #expect(message.contains("No response"))
        #expect(message.contains("revoked") || message.contains("offline"))
    }

    @Test func confirmedIsNotAFailure() {
        #expect(WalletStore.setupFailureMessage(for: .confirmed) == "Connected")
    }
}
