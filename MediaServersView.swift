import SwiftUI

struct MediaServersView: View {
    let keypair: Keypair
    @State private var viewModel: MediaServersViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draggedIndex: Int? = nil
    @State private var dragOffsetY: CGFloat = 0
    @State private var dragCorrection: CGFloat = 0
    @State private var rowHeight: CGFloat = 56

    init(keypair: Keypair) {
        self.keypair = keypair
        _viewModel = State(initialValue: MediaServersViewModel(pubkey: keypair.pubkey))
    }

    var body: some View {
        @Bindable var vm = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if keypair.isWatchOnly {
                    watchOnlyBanner
                }
                VStack(alignment: .leading, spacing: 16) {
                    addServerRow(vm: vm)
                    if let err = viewModel.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    publishButton
                    if viewModel.servers.count > 1 {
                        Text("Drag to reorder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    serverList
                }
                .disabled(keypair.isWatchOnly)
                .opacity(keypair.isWatchOnly ? 0.4 : 1)
            }
            .padding(20)
        }
        .background(Color.wispBackground.ignoresSafeArea())
        .navigationTitle("Media Servers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func addServerRow(vm: MediaServersViewModel) -> some View {
        HStack(spacing: 8) {
            TextField("https://...", text: Binding(
                get: { vm.newServerInput },
                set: { vm.newServerInput = $0 }
            ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { viewModel.addServer() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.wispSurfaceVariant.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 8))
            Button {
                viewModel.addServer()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(addDisabled ? .secondary : Color.wispPrimary)
            }
            .buttonStyle(.plain)
            .disabled(addDisabled)
        }
    }

    private var addDisabled: Bool {
        viewModel.newServerInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var publishButton: some View {
        Button {
            Task { await viewModel.publish(keypair: keypair) }
        } label: {
            HStack(spacing: 8) {
                if case .publishing = viewModel.publishState {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                Text(publishLabel)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(publishBackground, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(publishDisabled)
    }

    private var publishLabel: String {
        switch viewModel.publishState {
        case .idle: return "Publish to relays"
        case .publishing: return "Publishing\u{2026}"
        case .sent: return "Sent ✓"
        case .failed(let reason): return "Try again — \(reason)"
        }
    }

    private var publishBackground: Color {
        switch viewModel.publishState {
        case .sent: return .green
        case .failed: return .red
        default: return Color.wispPrimary
        }
    }

    private var publishDisabled: Bool {
        if case .publishing = viewModel.publishState { return true }
        return false
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.servers.enumerated()), id: \.element) { pair in
                let index = pair.offset
                let url = pair.element
                serverRow(index: index, url: url)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                if rowHeight == 56 {
                                    rowHeight = max(proxy.size.height, 1)
                                }
                            }
                    })
                if index != viewModel.servers.count - 1 {
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
                }
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 12))
        .animation(.easeInOut(duration: 0.18), value: viewModel.servers)
    }

    @ViewBuilder
    private func serverRow(index: Int, url: String) -> some View {
        HStack(spacing: 12) {
            if viewModel.servers.count > 1 {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(rowIndex: index))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(url)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if index == 0 {
                    Text("Primary")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.wispPrimary)
                }
            }
            Spacer(minLength: 8)
            Button {
                viewModel.removeServer(at: IndexSet(integer: index))
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(draggedIndex == index ? Color.wispSurfaceVariant.opacity(0.6) : Color.clear)
        .offset(y: draggedIndex == index ? dragOffsetY : 0)
        .zIndex(draggedIndex == index ? 1 : 0)
    }

    private func dragGesture(rowIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if draggedIndex == nil {
                    draggedIndex = rowIndex
                    dragCorrection = 0
                }
                dragOffsetY = value.translation.height - dragCorrection
                guard rowHeight > 0, let current = draggedIndex else { return }
                let steps = Int((dragOffsetY / rowHeight).rounded())
                let target = max(0, min(viewModel.servers.count - 1, current + steps))
                if target != current {
                    viewModel.moveServer(from: current, to: target)
                    dragCorrection += CGFloat(target - current) * rowHeight
                    dragOffsetY = value.translation.height - dragCorrection
                    draggedIndex = target
                }
            }
            .onEnded { _ in
                draggedIndex = nil
                dragOffsetY = 0
                dragCorrection = 0
            }
    }

    private var watchOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .foregroundStyle(Color.wispPrimary)
                .font(.subheadline)
                .padding(.top, 2)
            Text("Watch-only mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}
