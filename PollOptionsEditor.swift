import SwiftUI

/// Duration presets for the poll end-date chip row.
enum PollDurationPreset: CaseIterable, Identifiable {
    case oneHour, sixHours, twelveHours, oneDay, threeDays, sevenDays

    var id: Self { self }

    var label: String {
        switch self {
        case .oneHour:     return "1h"
        case .sixHours:    return "6h"
        case .twelveHours: return "12h"
        case .oneDay:      return "1d"
        case .threeDays:   return "3d"
        case .sevenDays:   return "7d"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .oneHour:     return 3_600
        case .sixHours:    return 6 * 3_600
        case .twelveHours: return 12 * 3_600
        case .oneDay:      return 24 * 3_600
        case .threeDays:   return 3 * 24 * 3_600
        case .sevenDays:   return 7 * 24 * 3_600
        }
    }
}

/// Inline composer block shown when `pollEnabled` is true. Lets the user pick
/// Standard vs Zap, edit 2–10 option labels, toggle single/multi-choice (standard
/// only), and set min/max sats (zap only). Duration is chosen via a preset chip
/// row that defaults to 1 day; ∞ removes the end date; Custom reveals a DatePicker.
struct PollOptionsEditor: View {
    @Bindable var viewModel: ComposeViewModel

    @State private var minSatsText: String = ""
    @State private var maxSatsText: String = ""
    /// Active preset, or nil when ∞ / Custom is selected.
    @State private var selectedPreset: PollDurationPreset? = .oneDay
    @State private var isCustom = false
    @State private var customDate: Date = Date().addingTimeInterval(24 * 3_600)

    private static let endDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Poll type", selection: Binding(
                get: { viewModel.isZapPoll },
                set: { newValue in
                    if newValue != viewModel.isZapPoll { viewModel.toggleZapPoll() }
                }
            )) {
                Text("Standard").tag(false)
                Text("Zap").tag(true)
            }
            .pickerStyle(.segmented)

            VStack(spacing: 8) {
                ForEach(viewModel.pollOptions.indices, id: \.self) { idx in
                    HStack(spacing: 8) {
                        TextField("Option \(idx + 1)", text: Binding(
                            get: { viewModel.pollOptions[idx] },
                            set: { viewModel.updatePollOption(at: idx, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        if viewModel.pollOptions.count > 2 {
                            Button {
                                viewModel.removePollOption(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if viewModel.pollOptions.count < 10 {
                    Button {
                        viewModel.addPollOption()
                    } label: {
                        Label("Add option", systemImage: "plus.circle")
                            .font(.subheadline)
                            .foregroundStyle(Color.wispPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if viewModel.isZapPoll {
                zapControls
            } else {
                standardControls
            }

            durationRow
        }
        .padding(12)
        .background(Color.wispSurfaceVariant.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            applyPreset(.oneDay)
        }
    }

    private var standardControls: some View {
        Toggle(isOn: Binding(
            get: { viewModel.pollType == .multiplechoice },
            set: { _ in viewModel.togglePollType() }
        )) {
            Text("Multiple choice").font(.subheadline)
        }
        .tint(Color.wispPrimary)
    }

    private var zapControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Min sats", text: $minSatsText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .onChange(of: minSatsText) { _, new in
                        viewModel.zapPollMinSats = Int(new)
                    }
                TextField("Max sats", text: $maxSatsText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .onChange(of: maxSatsText) { _, new in
                        viewModel.zapPollMaxSats = Int(new)
                    }
            }
            Text("Optional. Voters can zap any amount within this range.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var durationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duration")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PollDurationPreset.allCases) { preset in
                        chip(label: preset.label, selected: selectedPreset == preset && !isCustom) {
                            isCustom = false
                            applyPreset(preset)
                        }
                    }
                    chip(label: "∞", selected: selectedPreset == nil && !isCustom) {
                        isCustom = false
                        selectedPreset = nil
                        viewModel.setPollEndsAt(nil)
                    }
                }
                .padding(.vertical, 2)
            }

            Toggle(isOn: $isCustom) {
                Text("Custom end date")
                    .font(.subheadline)
            }
            .tint(Color.wispPrimary)
            .onChange(of: isCustom) { _, custom in
                if custom {
                    selectedPreset = nil
                    viewModel.setPollEndsAt(Int(customDate.timeIntervalSince1970))
                } else {
                    applyPreset(.oneDay)
                }
            }

            if isCustom {
                DatePicker(
                    "",
                    selection: $customDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .onChange(of: customDate) { _, new in
                    viewModel.setPollEndsAt(Int(new.timeIntervalSince1970))
                }
            }

            if let endsAt = viewModel.pollEndsAt {
                let endDate = Date(timeIntervalSince1970: TimeInterval(endsAt))
                Text("Ends \(Self.endDateFormatter.string(from: endDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.wispPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.wispPrimary : Color.wispPrimary.opacity(0.12),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func applyPreset(_ preset: PollDurationPreset) {
        selectedPreset = preset
        let ts = Int(Date().addingTimeInterval(preset.seconds).timeIntervalSince1970)
        viewModel.setPollEndsAt(ts)
    }
}
