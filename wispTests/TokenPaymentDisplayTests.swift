import Foundation
import Testing
@testable import wisp

/// Spark wallets hold tokens alongside sats, and `Payment.amount` is
/// documented as "satoshis **or** token base units". Wisp offers no token
/// conversion, but a wallet restored from the same seed in an app that does
/// hands us those payments anyway — and reading their base units as sats
/// turned a $150 stablecoin transfer into "15,766,673 sats".
struct TokenAmountScalingTests {

    // MARK: - Decimal shifting

    @Test func scalesByTheTokensDecimals() {
        // USDB-shaped: 6 decimals. The screenshot's 15,766,673 base units is
        // 15.766673 USDB, not 15.7M sats.
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "15766673", decimals: 6) == "15.766673")
    }

    @Test func trailingZerosAreDropped() {
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "150000000", decimals: 6) == "150")
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "1500000", decimals: 6) == "1.5")
    }

    /// Amounts smaller than one whole unit need a leading zero, not ".5".
    @Test func amountsUnderOneUnitKeepTheirLeadingZero() {
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "500000", decimals: 6) == "0.5")
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "1", decimals: 6) == "0.000001")
    }

    @Test func zeroDecimalsPassesThrough() {
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "42", decimals: 0) == "42")
    }

    @Test func zeroIsZero() {
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "0", decimals: 6) == "0")
    }

    /// Base units are `U128`. Anything routed through `Int64` would overflow
    /// and silently read as 0, so the scaler works on the decimal string.
    @Test func amountsBeyondInt64Survive() {
        let huge = "340282366920938463463374607431768211455"  // U128.max
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: huge, decimals: 2)
                == "3402823669209384634633746074317682114.55")
    }

    // MARK: - Row-sized display

    /// USDB is dollars. Six decimal places is both unreadable at a glance and
    /// wrong for what the number means.
    @Test func compactFormRoundsToTwoPlaces() {
        #expect(WalletTransaction.compactTokenAmount("15.766673") == "15.77")
        #expect(WalletTransaction.compactTokenAmount("15.802229") == "15.80")
    }

    @Test func wholeAmountsStillShowTwoPlaces() {
        // "150" has no decimal point, so it passes through as-is — a whole
        // token count doesn't need padding to look like money.
        #expect(WalletTransaction.compactTokenAmount("150") == "150")
        #expect(WalletTransaction.compactTokenAmount("150.0") == "150.00")
    }

    /// Dust must never render as "0.00" — that reads as nothing arriving.
    @Test func dustKeepsFullPrecision() {
        #expect(WalletTransaction.compactTokenAmount("0.000001") == "0.000001")
    }

    @Test func realZeroIsAllowedToBeZero() {
        #expect(WalletTransaction.compactTokenAmount("0.0") == "0.00")
    }

    @Test func compactFormGroupsThousands() {
        #expect(WalletTransaction.compactTokenAmount("1234.5") == "1,234.50")
    }

    /// The row shows the compact form; the detail sheet keeps every digit.
    @Test func fullPrecisionSurvivesOnTheModel() {
        var tx = WalletTransaction(
            type: .incoming, description: nil, paymentHash: "h",
            amountMsats: 0, feeMsats: 0, createdAt: 0, settledAt: nil,
            counterpartyPubkey: nil
        )
        tx.assetTicker = "USDB"
        tx.assetAmount = "15.766673"
        #expect(tx.assetAmountCompact == "15.77")
        #expect(tx.assetAmount == "15.766673")
    }

    /// Never crash or fabricate a number on unexpected input.
    @Test func nonNumericInputIsReturnedUnchanged() {
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "abc", decimals: 6) == "abc")
        #expect(WalletTransaction.scaleTokenAmount(baseUnits: "", decimals: 6) == "")
    }
}

struct TokenTransactionRowTests {

    private func tx(assetTicker: String? = nil, assetAmount: String? = nil,
                    amountMsats: Int64 = 0, paymentHash: String = "abc-def") -> WalletTransaction {
        var t = WalletTransaction(
            type: .incoming, description: nil, paymentHash: paymentHash,
            amountMsats: amountMsats, feeMsats: 0, createdAt: 0, settledAt: nil,
            counterpartyPubkey: nil
        )
        t.assetTicker = assetTicker
        t.assetAmount = assetAmount
        return t
    }

    @Test func aSatsRowIsNotATokenTransfer() {
        #expect(!tx(amountMsats: 21_000).isTokenTransfer)
    }

    @Test func anAssetTickerMarksATokenTransfer() {
        #expect(tx(assetTicker: "USDB", assetAmount: "15.766673").isTokenTransfer)
    }

    /// `isOnchain` keys off hyphens in the id (Spark's on-chain rows are
    /// UUIDs). A token tx hash can carry them too, and labelling a stablecoin
    /// transfer "On-chain" would send someone hunting for it on a block
    /// explorer.
    @Test func aTokenTransferIsNeverOnchain() {
        #expect(!tx(assetTicker: "USDB", assetAmount: "1", paymentHash: "a-b-c").isOnchain)
    }

    @Test func aHyphenatedSatsRowIsStillOnchain() {
        #expect(tx(paymentHash: "a-b-c").isOnchain)
    }

    /// Rows cached before this field existed must still decode.
    @Test func legacyCachedRowsDecodeWithoutAnAsset() throws {
        let legacy = """
        {"type":"incoming","paymentHash":"h","amountMsats":21000,"feeMsats":0,
         "createdAt":1,"settledAt":1}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WalletTransaction.self, from: legacy)
        #expect(decoded.assetTicker == nil)
        #expect(!decoded.isTokenTransfer)
        #expect(decoded.amountMsats == 21_000)
    }
}
