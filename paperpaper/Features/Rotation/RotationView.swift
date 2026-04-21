import SwiftUI
import SwiftData

struct RotationView: View {
    @Query private var rules: [RotationRule]
    @State private var engine = RotationEngine.shared

    private var rule: RotationRule { rules.first ?? Store.shared.rule() }

    var body: some View {
        Form {
            Section("Schedule") {
                Toggle("Enable rotation", isOn: Binding(
                    get: { rule.enabled },
                    set: { newValue in
                        rule.enabled = newValue
                        try? Store.shared.context.save()
                        if newValue { engine.start() } else { engine.stop() }
                    }
                ))

                HStack {
                    Text("Interval")
                    Slider(
                        value: Binding(
                            get: { Double(rule.intervalSeconds) },
                            set: { rule.intervalSeconds = Int($0); try? Store.shared.context.save() }
                        ),
                        in: 5...(60 * 60 * 12),
                        step: 5
                    )
                    Text(formatInterval(rule.intervalSeconds))
                        .monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }

                Picker("Day/night", selection: Binding(
                    get: { rule.dayNightMode },
                    set: { rule.dayNightMode = $0; try? Store.shared.context.save() }
                )) {
                    Text("Off").tag(DayNightMode.off)
                    Text("Separate pools").tag(DayNightMode.separatePools)
                    Text("Separate intervals").tag(DayNightMode.separateIntervals)
                }

                if rule.dayNightMode == .separateIntervals {
                    HStack {
                        Text("Night interval")
                        Slider(
                            value: Binding(
                                get: { Double(rule.nightIntervalSeconds) },
                                set: { rule.nightIntervalSeconds = Int($0); try? Store.shared.context.save() }
                            ),
                            in: 5...(60 * 60 * 12),
                            step: 5
                        )
                        Text(formatInterval(rule.nightIntervalSeconds))
                            .monospacedDigit()
                            .frame(width: 110, alignment: .trailing)
                    }
                }

                if rule.dayNightMode != .off {
                    HStack {
                        Stepper("Day starts at \(rule.dayStartHour):00", value: Binding(
                            get: { rule.dayStartHour },
                            set: { rule.dayStartHour = $0; try? Store.shared.context.save() }
                        ), in: 0...23)
                        Stepper("Night starts at \(rule.nightStartHour):00", value: Binding(
                            get: { rule.nightStartHour },
                            set: { rule.nightStartHour = $0; try? Store.shared.context.save() }
                        ), in: 0...23)
                    }
                }
            }

            Section("Spaces") {
                Picker("Behavior", selection: Binding(
                    get: { rule.spaceMode },
                    set: { rule.spaceMode = $0; try? Store.shared.context.save() }
                )) {
                    Text("Unified").tag(SpaceMode.unified)
                    Text("Per-Space").tag(SpaceMode.perSpace)
                    Text("Active only").tag(SpaceMode.activeOnly)
                }
                .pickerStyle(.radioGroup)
                Text("Per-Space and Active-only only update the wallpaper when that Space becomes active (macOS API limitation).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Repeats") {
                Toggle("Allow photos to repeat", isOn: Binding(
                    get: { rule.allowRepeats },
                    set: { rule.allowRepeats = $0; try? Store.shared.context.save() }
                ))
                if !rule.allowRepeats {
                    Stepper("Cooldown: \(rule.repeatCooldownDays) days", value: Binding(
                        get: { rule.repeatCooldownDays },
                        set: { rule.repeatCooldownDays = $0; try? Store.shared.context.save() }
                    ), in: 1...365)
                }
            }

            Section("Status") {
                LabeledContent("Running", value: engine.isRunning ? "Yes" : "No")
                if let next = engine.nextFireAt {
                    LabeledContent("Next rotation", value: next.formatted(date: .omitted, time: .standard))
                }
                if let err = engine.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Button("Rotate now") {
                    Task { await engine.rotateNow() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

#Preview {
    RotationView()
        .modelContainer(Store.shared.container)
        .frame(width: 900, height: 600)
}
