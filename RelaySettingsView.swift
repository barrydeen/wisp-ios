import SwiftUI

struct RelaySettingsView: View {
    let keypair: Keypair

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var repo = RelaySettingsRepository.shared
    @State private var settings = AppSettings.shared
    @State private var tab: Tab = .general
    @State private var newUrl: String = ""
    @State private var inputError: String?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var syncing = false

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case dm      = "DM"
        case search  = "Search"
        case blocked = "Blocked"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Section {
                Picker("Tab", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if tab == .general {
                Section {
                    Toggle("Sign in to relays automatically", isOn: $settings.autoApproveRelayAuth)
                        .tint(theme.primary)
                        .font(.system(size: 14))
                        .listRowBackground(theme.palette.surface)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }

            Section {
                addRelayField
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            Section {
                let urls = currentUrls
                if urls.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 28))
                            .foregroundStyle(theme.palette.onSurfaceVariant.opacity(0.5))
                        Text("No \(tab.rawValue.lowercased()) relays yet")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.palette.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(urls, id: \.self) { url in
                        relayRow(url: url)
                            .listRowBackground(theme.palette.surface)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteCurrent(url: url)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    Text("Swipe left to delete")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.onSurfaceVariant.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16))
                }
            }

            Section {
                VStack(spacing: 10) {
                    Button(action: broadcastCurrent) {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(broadcastLabel)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(theme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        guard !syncing else { return }
                        syncing = true
                        Task {
                            await repo.syncFromNetwork(keypair: keypair)
                            syncing = false
                            showToast("Synced from network")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if syncing {
                                ProgressView().tint(theme.primary).scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            Text(syncing ? "Syncing…" : "Sync Relay List (NIP-65)")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(theme.primary)
                        .background(theme.palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(syncing)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { toastView }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Pieces

    private var addRelayField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("wss://relay.example.com", text: $newUrl)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(theme.palette.surfaceVariant)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: addCurrent) {
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(theme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(newUrl.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let inputError {
                Text(inputError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func relayRow(url: String) -> some View {
        HStack(spacing: 8) {
            Text(url
                .replacingOccurrences(of: "wss://", with: "")
                .replacingOccurrences(of: "ws://", with: ""))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(theme.palette.onSurface)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if tab == .general,
               let relay = repo.generalRelays.first(where: { $0.url == url }) {
                chip(label: "read", on: relay.read) { repo.toggleGeneralRead(url, keypair: keypair) }
                chip(label: "write", on: relay.write) { repo.toggleGeneralWrite(url, keypair: keypair) }
            }
        }
    }

    @ViewBuilder
    private func chip(label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(on ? .white : theme.palette.onSurfaceVariant)
                .background(on ? theme.primary : theme.palette.surfaceVariant)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.palette.onSurface.opacity(0.9))
                .clipShape(Capsule())
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var currentUrls: [String] {
        switch tab {
        case .general: return repo.generalRelays.map(\.url)
        case .dm:      return repo.dmRelays
        case .search:  return repo.searchRelays
        case .blocked: return repo.blockedRelays
        }
    }

    private var broadcastLabel: String {
        switch tab {
        case .general: return "Broadcast Relay List (NIP-65)"
        case .dm:      return "Broadcast DM Relays"
        case .search:  return "Broadcast Search Relays"
        case .blocked: return "Broadcast Blocked Relays"
        }
    }

    private func addCurrent() {
        let trimmed = newUrl.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard Nip51Lists.normalize(trimmed) != nil else {
            inputError = "Must be a wss:// or ws:// URL"
            return
        }
        inputError = nil
        switch tab {
        case .general: repo.addGeneralRelay(trimmed, keypair: keypair)
        case .dm:      repo.addDmRelay(trimmed, keypair: keypair)
        case .search:  repo.addSearchRelay(trimmed, keypair: keypair)
        case .blocked: repo.addBlockedRelay(trimmed, keypair: keypair)
        }
        newUrl = ""
    }

    private func deleteCurrent(url: String) {
        switch tab {
        case .general: repo.removeGeneralRelay(url, keypair: keypair)
        case .dm:      repo.removeDmRelay(url, keypair: keypair)
        case .search:  repo.removeSearchRelay(url, keypair: keypair)
        case .blocked: repo.removeBlockedRelay(url, keypair: keypair)
        }
    }

    private func broadcastCurrent() {
        switch tab {
        case .general: repo.broadcastGeneral(keypair: keypair)
        case .dm:      repo.broadcastDm(keypair: keypair)
        case .search:  repo.broadcastSearch(keypair: keypair)
        case .blocked: repo.broadcastBlocked(keypair: keypair)
        }
        showToast("Broadcasting…")
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation { toast = text }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toast = nil }
        }
    }
}
