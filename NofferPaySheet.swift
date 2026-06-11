import SwiftUI

/// Inline "Pay offer" pill rendered for a CLINK `noffer1…` found in a note body
/// or a profile. Tapping opens `NofferPaySheet`. Brand accent follows the
/// theme's zap color to read as a Lightning payment affordance.
struct NofferButton: View {
    let noffer: NofferData
    /// Resolved recipient profile, when the caller already has it (profile
    /// pages, feed rows). The sheet resolves it on its own otherwise.
    var recipientProfile: ProfileData? = nil

    @Environment(WalletStore.self) private var walletStore: WalletStore?
    @State private var showSheet = false
    /// Recipient resolved by the card itself, so the subtitle reads the same
    /// name everywhere instead of depending on whether the caller's profile map
    /// happened to include the offer's pubkey (it's the offer recipient, not
    /// the note author, so feed rows often hadn't fetched it yet).
    @State private var resolvedProfile: ProfileData?

    private var recipientName: String {
        (recipientProfile ?? resolvedProfile)?.displayString ?? Nip19.shortNpub(hex: noffer.pubkey)
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.wispZapColor)
                    .frame(width: 30, height: 30)
                    .background(Color.wispZapColor.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Pay offer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(recipientName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let price = noffer.price, price > 0 {
                    Text(priceLabel(price))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.wispZapColor)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.wispZapColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.wispZapColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            NofferPaySheet(noffer: noffer, recipientProfile: recipientProfile ?? resolvedProfile, store: walletStore)
        }
        .task {
            // Resolve the recipient name if the caller didn't already pass one.
            guard recipientProfile == nil else { return }
            resolvedProfile = ProfileRepository.shared.get(noffer.pubkey)
            let fetched = await ProfileRepository.shared.ensure([noffer.pubkey])
            if let p = fetched[noffer.pubkey] { resolvedProfile = p }
        }
    }

    private func priceLabel(_ price: Int64) -> String {
        if let currency = noffer.currency, !currency.isEmpty {
            return "\(CurrencyFormatter.formatNumber(price)) \(currency)"
        }
        return "\(CurrencyFormatter.formatNumber(price)) sats"
    }
}

/// Modal that requests a bolt11 invoice for a CLINK offer and pays it with the
/// active wallet, or falls back to a scannable `noffer1…` QR for an external
/// CLINK-aware wallet (Zeus, ShockWallet, …).
struct NofferPaySheet: View {
    let noffer: NofferData
    var recipientProfile: ProfileData?
    var store: WalletStore?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var resolvedProfile: ProfileData?
    @State private var amountText: String = ""
    @State private var status: String?
    @State private var inFlight = false
    @State private var didPay = false
    @State private var showExternal = false

    private var recipientName: String {
        (resolvedProfile ?? recipientProfile)?.displayString ?? Nip19.shortNpub(hex: noffer.pubkey)
    }

    private var amountSats: Int64? {
        guard let v = Int64(amountText.filter { $0.isNumber }), v > 0 else { return nil }
        return v
    }

    /// Spontaneous offers require the payer to name an amount. Fixed/Variable
    /// let the service decide (Fixed from the offer, Variable on request).
    private var needsAmountField: Bool { noffer.pricing == .spontaneous }

    private var canPayInApp: Bool {
        guard store != nil, !inFlight else { return false }
        return needsAmountField ? amountSats != nil : true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    recipientHeader

                    if didPay {
                        successView
                    } else {
                        offerDetails
                        if needsAmountField { amountField }
                        if let status {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                Text(status).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        payButton
                        externalWalletSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color.wispBackground.ignoresSafeArea())
            .navigationTitle("Pay offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(didPay ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .task {
            // Fill in the recipient's name/avatar if the caller didn't pass one.
            if recipientProfile == nil {
                resolvedProfile = ProfileRepository.shared.get(noffer.pubkey)
                let fetched = await ProfileRepository.shared.ensure([noffer.pubkey])
                if let p = fetched[noffer.pubkey] { resolvedProfile = p }
            }
            // Prefill a variable offer's amount field with its sat hint.
            if amountText.isEmpty, needsAmountField, let price = noffer.price, price > 0 {
                amountText = String(price)
            }
        }
    }

    // MARK: - Sections

    private var recipientHeader: some View {
        VStack(spacing: 10) {
            CachedAvatarView(url: (resolvedProfile ?? recipientProfile)?.picture, size: 64, alwaysLoad: true)
                .overlay(Circle().stroke(Color.wispZapColor.opacity(0.3), lineWidth: 2))
            Text(recipientName)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var offerDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Offer")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(pricingLabel)
                    .font(.subheadline.weight(.semibold))
            }
            if let price = noffer.price, price > 0, !needsAmountField {
                HStack {
                    Text("Amount")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(priceLabel(price))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.wispZapColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.wispSurfaceVariant.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var amountField: some View {
        HStack {
            Image(systemName: settings.zapSymbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("Amount in sats", text: $amountText)
                .keyboardType(.numberPad)
                .font(.system(.body, design: .rounded))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.wispSurfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var payButton: some View {
        Button {
            Task { await pay() }
        } label: {
            Group {
                if inFlight {
                    ProgressView().tint(.white)
                } else {
                    Text(store == nil ? "Connect a wallet to pay" : "Pay")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canPayInApp ? Color.wispZapColor : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!canPayInApp)
    }

    private var externalWalletSection: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showExternal.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "qrcode")
                    Text(showExternal ? "Hide QR code" : "Pay with another wallet")
                    Image(systemName: showExternal ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.wispZapColor)
            }
            .buttonStyle(.plain)

            // Clip container pinned directly below the toggle button: the QR
            // slides in from its top edge and is masked to this region, so it
            // emerges cropped from under the button instead of drawing over it.
            VStack(spacing: 0) {
                if showExternal {
                    VStack(spacing: 12) {
                        QRCodeImage(payload: noffer.raw, sideLength: 230)
                            .padding(12)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        Text("Scan with Zeus, ShockWallet, or another CLINK-aware wallet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            UIPasteboard.general.string = noffer.raw
                            QuickFollowToast.shared.show("Copied")
                        } label: {
                            Label("Copy offer", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.wispZapColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
        }
        .padding(.top, 4)
    }

    private var successView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.wispZapColor)
            Text("Payment sent")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Pay

    private func pay() async {
        guard let store else { return }
        guard let keypair = NostrKey.load() else {
            status = "Sign in to pay an offer."
            return
        }
        inFlight = true
        status = nil
        defer { inFlight = false }

        let amount: Int64? = needsAmountField ? amountSats : nil
        do {
            let bolt11 = try await NofferClient.requestInvoice(
                noffer: noffer,
                keypair: keypair,
                amountSats: amount
            )
            switch await store.payInvoice(bolt11) {
            case .success:
                withAnimation { didPay = true }
            case .failure(let err):
                status = err.localizedDescription
            }
        } catch let err as NofferError {
            status = friendlyMessage(for: err)
        } catch {
            status = error.localizedDescription
        }
    }

    private func friendlyMessage(for err: NofferError) -> String {
        if err.code == 5, let range = err.range {
            return "Amount must be between \(CurrencyFormatter.formatNumber(range.min)) and \(CurrencyFormatter.formatNumber(range.max)) sats."
        }
        return err.message
    }

    // MARK: - Labels

    private var pricingLabel: String {
        switch noffer.pricing {
        case .fixed: return "Fixed price"
        case .variable: return "Variable price"
        case .spontaneous: return "Pay what you want"
        }
    }

    private func priceLabel(_ price: Int64) -> String {
        if let currency = noffer.currency, !currency.isEmpty {
            return "\(CurrencyFormatter.formatNumber(price)) \(currency)"
        }
        return "\(CurrencyFormatter.formatNumber(price)) sats"
    }
}
