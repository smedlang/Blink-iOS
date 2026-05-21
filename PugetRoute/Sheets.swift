import SwiftUI

// MARK: - Time target sheet

/// Sheet that lets the user pick between "Leave now", "Depart at", "Arrive by"
/// and choose a specific time.
struct TimeTargetSheet: View {
    @Binding var target: TimeTarget
    /// Called with the final target after the user taps Done.
    var onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case now = "Leave now"
        case depart = "Depart at"
        case arrive = "Arrive by"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .now
    @State private var date: Date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

                if kind != .now {
                    DatePicker(
                        kind == .depart ? "Depart at" : "Arrive by",
                        selection: $date,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                }
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        switch kind {
                        case .now:    target = .leaveNow
                        case .depart: target = .leaveAt(date)
                        case .arrive: target = .arriveBy(date)
                        }
                        dismiss()
                        onCommit()
                    }
                }
            }
            .onAppear {
                // Seed the picker from the existing target.
                switch target {
                case .leaveNow:
                    kind = .now
                    date = Date()
                case .leaveAt(let d):
                    kind = .depart
                    date = d
                case .arriveBy(let d):
                    kind = .arrive
                    date = d
                }
            }
        }
    }
}

// MARK: - Preferences sheet

/// Sheet where the user picks how OTP should weight its options:
/// pure speed, less biking/walking, or safer bike routing.
struct PreferencesSheet: View {
    @Binding var preference: RoutePreference
    @Binding var bikePace: BikePace
    @Binding var bikeKind: BikeKind
    var onCommit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Route preference") {
                    ForEach(RoutePreference.allCases) { p in
                        HStack {
                            Image(systemName: icon(for: p))
                                .foregroundColor(.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.rawValue).font(.body).bold()
                                Text(blurb(for: p))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if preference == p {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { preference = p }
                    }
                }

                // Bike type — Standard vs E-Bike. Selecting E-Bike
                // overrides pace with a fixed 18 mph cruise (motor-
                // determined, not rider-determined) and drops the
                // client-side climb penalty so hilly direct routes win
                // over flat detours. When E-Bike is selected the Pace
                // section is hidden — there's no meaningful "casual vs.
                // brisk" on a class-2/3 e-bike.
                Section {
                    ForEach(BikeKind.allCases) { kind in
                        HStack {
                            Image(systemName: kind.icon)
                                .foregroundColor(.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.label).font(.body).bold()
                                Text(kind.blurb)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if bikeKind == kind {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { bikeKind = kind }
                    }
                } header: {
                    Text("Bike type")
                }

                // Bike pace drives both OTP's bike-leg duration estimates
                // (via the `bikeSpeed` GraphQL variable, which also affects
                // which buses you can realistically catch) and the live ETA
                // shown during navigation. If the durations consistently feel
                // too long, picking a faster pace fixes it everywhere at once.
                //
                // Hidden when the user has selected E-Bike — bikeSpeed is
                // fixed at 18 mph in that mode and pace doesn't apply.
                if bikeKind == .standard {
                    Section {
                        Picker("Pace", selection: $bikePace) {
                            ForEach(BikePace.allCases) { pace in
                                Text("\(Int(pace.mph.rounded()))")
                                    .tag(pace)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Bike pace (mph)")
                    }
                }
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        onCommit()
                    }
                }
            }
        }
    }

    private func icon(for p: RoutePreference) -> String {
        switch p {
        case .fastest:    return "hare"
        case .lessActive: return "figure.seated.side"
        }
    }

    private func blurb(for p: RoutePreference) -> String {
        switch p {
        case .fastest:
            return "Minimum total travel time. Bike legs still prefer protected lanes."
        case .lessActive:
            return "Use transit more, bike or walk less even if it takes longer."
        }
    }
}
