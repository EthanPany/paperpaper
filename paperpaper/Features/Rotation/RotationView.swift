import SwiftUI
import SwiftData
import CoreLocation

struct RotationView: View {
    @Query private var rules: [RotationRule]
    @Query private var filterRows: [FilterPrefs]
    @State private var engine = RotationEngine.shared
    @State private var newTopic: String = ""
    @State private var newExclusion: String = ""
    @State private var customIntervalValue: Int = 60
    @State private var customIntervalUnit: IntervalUnit = .minutes
    @State private var showingCustomInterval: Bool = false
    @State private var newTimeHour: Int = 9
    @State private var newTimeMinute: Int = 0

    private var rule: RotationRule { rules.first ?? Store.shared.rule() }
    private var filters: FilterPrefs { filterRows.first ?? Store.shared.filters() }
    @State private var locationStatus: CLAuthorizationStatus = LocationService.shared.authorizationStatus

    private let presetIntervals: [IntervalPreset] = [
        IntervalPreset(label: "15 min", seconds: 15 * 60),
        IntervalPreset(label: "30 min", seconds: 30 * 60),
        IntervalPreset(label: "1 h", seconds: 60 * 60),
        IntervalPreset(label: "2 h", seconds: 120 * 60),
        IntervalPreset(label: "4 h", seconds: 240 * 60),
        IntervalPreset(label: "12 h", seconds: 720 * 60),
        IntervalPreset(label: "24 h", seconds: 1440 * 60),
    ]

    var body: some View {
        Form {
            scheduleSection
            modeSection
            daysSection
            spacesSection
            repeatsSection
            nearbySection
            topicsSection
            filtersSection
            statusSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        Section("Rotation") {
            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    rule.enabled = newValue
                    try? Store.shared.context.save()
                    if newValue { engine.start() } else { engine.stop() }
                }
            ))

            Picker("Mode", selection: Binding(
                get: { rule.scheduleMode },
                set: { rule.scheduleMode = $0; try? Store.shared.context.save() }
            )) {
                Text("Every N minutes").tag(ScheduleMode.interval)
                Text("At specific times").tag(ScheduleMode.specificTimes)
            }
        }
    }

    @ViewBuilder
    private var modeSection: some View {
        if rule.scheduleMode == .interval {
            Section("Interval") {
                let isPreset = presetIntervals.contains { $0.seconds == rule.intervalSeconds } && !showingCustomInterval
                HStack(spacing: 6) {
                    ForEach(0..<presetIntervals.count, id: \.self) { index in
                        let preset = presetIntervals[index]
                        let selected = isPreset && rule.intervalSeconds == preset.seconds
                        Button {
                            rule.intervalSeconds = preset.seconds
                            showingCustomInterval = false
                            try? Store.shared.context.save()
                        } label: {
                            Text(preset.label)
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(selected ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                        .controlSize(.small)
                    }
                    Button {
                        showingCustomInterval = true
                    } label: {
                        Text("Custom")
                            .font(.caption)
                    }
                    .buttonStyle(showingCustomInterval || !isPreset ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                    .controlSize(.small)
                }

                if showingCustomInterval || !presetIntervals.contains(where: { $0.seconds == rule.intervalSeconds }) {
                    HStack {
                        TextField("Value", value: $customIntervalValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Picker("", selection: $customIntervalUnit) {
                            Text("seconds").tag(IntervalUnit.seconds)
                            Text("minutes").tag(IntervalUnit.minutes)
                            Text("hours").tag(IntervalUnit.hours)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Button("Apply") {
                            rule.intervalSeconds = max(5, customIntervalValue * customIntervalUnit.toSeconds)
                            try? Store.shared.context.save()
                        }
                        Spacer()
                    }
                    .onAppear {
                        let secs = rule.intervalSeconds
                        if secs % 3600 == 0 {
                            customIntervalValue = secs / 3600
                            customIntervalUnit = .hours
                        } else if secs % 60 == 0 {
                            customIntervalValue = secs / 60
                            customIntervalUnit = .minutes
                        } else {
                            customIntervalValue = secs
                            customIntervalUnit = .seconds
                        }
                    }
                }

                Toggle("Align to clock (e.g. every hour at :00)", isOn: Binding(
                    get: { rule.alignToClock },
                    set: { rule.alignToClock = $0; try? Store.shared.context.save() }
                ))
            }
        } else {
            Section("Specific times") {
                if rule.specificMinutesOfDay.isEmpty {
                    Text("No times set — add one below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let sortedTimes = rule.specificMinutesOfDay.sorted()
            ForEach(0..<sortedTimes.count, id: \.self) { idx in
                let minuteOfDay = sortedTimes[idx]
                    HStack {
                        Text(formatMinuteOfDay(minuteOfDay))
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Button(role: .destructive) {
                            rule.specificMinutesOfDay.removeAll { $0 == minuteOfDay }
                            try? Store.shared.context.save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 8) {
                    Stepper(value: $newTimeHour, in: 0...23) {
                        Text(String(format: "%02d", newTimeHour)).monospacedDigit()
                    }
                    .fixedSize()
                    Text(":")
                    Stepper(value: $newTimeMinute, in: 0...59, step: 5) {
                        Text(String(format: "%02d", newTimeMinute)).monospacedDigit()
                    }
                    .fixedSize()
                    Button("Add") {
                        let value = newTimeHour * 60 + newTimeMinute
                        if !rule.specificMinutesOfDay.contains(value) {
                            rule.specificMinutesOfDay.append(value)
                            try? Store.shared.context.save()
                        }
                    }
                    .buttonStyle(.glass)
                    Spacer()
                }
            }
        }
    }

    private var daysSection: some View {
        Section("Days of week") {
            HStack(spacing: 6) {
                let days = Weekday.allCases
                ForEach(0..<days.count, id: \.self) { index in
                    let day = days[index]
                    let on = rule.daysOfWeekMask & day.bit != 0
                    Button {
                        if on { rule.daysOfWeekMask &= ~day.bit }
                        else { rule.daysOfWeekMask |= day.bit }
                        if rule.daysOfWeekMask == 0 { rule.daysOfWeekMask = 0b1111111 }
                        try? Store.shared.context.save()
                    } label: {
                        Text(day.shortLabel)
                            .font(.caption.monospaced())
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(on ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                    .help(day.fullLabel)
                }
                Spacer()
                Button("All") {
                    rule.daysOfWeekMask = 0b1111111
                    try? Store.shared.context.save()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Button("Weekdays") {
                    rule.daysOfWeekMask = 0b0111110
                    try? Store.shared.context.save()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private var spacesSection: some View {
        Section("Spaces") {
            Picker("Behavior", selection: Binding(
                get: { rule.spaceMode },
                set: { rule.spaceMode = $0; try? Store.shared.context.save() }
            )) {
                Text("Unified").tag(SpaceMode.unified)
                Text("Per-Space").tag(SpaceMode.perSpace)
                Text("Active only").tag(SpaceMode.activeOnly)
            }
            .pickerStyle(.segmented)
            Text("Per-Space and Active-only only update the wallpaper when that Space becomes active (macOS API limitation).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var repeatsSection: some View {
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
    }

    private var nearbySection: some View {
        Section("Nearby") {
            Toggle("Prefer photos near my location", isOn: Binding(
                get: { rule.preferNearby },
                set: { newValue in
                    rule.preferNearby = newValue
                    try? Store.shared.context.save()
                    if newValue {
                        Task {
                            locationStatus = await LocationService.shared.requestAuthorization()
                        }
                    }
                }
            ))

            if rule.preferNearby {
                switch locationStatus {
                case .denied, .restricted:
                    Label("Location access denied. Open System Settings → Privacy & Security → Location Services to enable paperpaper.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .notDetermined:
                    Text("Click the toggle again to grant location access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    Text("Each rotation tries photos tagged near you first, then falls back to your topics if nothing matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Match Daylight", isOn: Binding(
                get: { rule.matchDaylight },
                set: { newValue in
                    rule.matchDaylight = newValue
                    try? Store.shared.context.save()
                    if newValue {
                        Task {
                            locationStatus = await LocationService.shared.requestAuthorization()
                        }
                    }
                }
            ))

            if rule.matchDaylight {
                Text("Picks brighter photos around solar noon and darker ones near night, based on the sun's position at your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var topicsSection: some View {
        Section("Topics") {
            HStack {
                TextField("Add a topic (e.g. brutalism)", text: $newTopic)
                    .onSubmit { addTopic() }
                Button("Add") { addTopic() }
                    .buttonStyle(.glass)
                    .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if filters.topics.isEmpty {
                Text("No topics — rotation will fall back to 'architecture'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filters.topics, id: \.self) { topic in
                    HStack {
                        Text(topic)
                        Spacer()
                        Button(role: .destructive) { removeTopic(topic) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var filtersSection: some View {
        Section("Filters") {
            LabeledContent("Aspect ratio") {
                HStack(spacing: 12) {
                    Stepper(value: Binding(
                        get: { filters.minAspect },
                        set: { filters.minAspect = min($0, filters.maxAspect); try? Store.shared.context.save() }
                    ), in: 0.5...3.0, step: 0.1) {
                        Text(String(format: "min %.1f", filters.minAspect))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Stepper(value: Binding(
                        get: { filters.maxAspect },
                        set: { filters.maxAspect = max($0, filters.minAspect); try? Store.shared.context.save() }
                    ), in: 0.5...3.0, step: 0.1) {
                        Text(String(format: "max %.1f", filters.maxAspect))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent("Country contains") {
                TextField("any", text: Binding(
                    get: { filters.countryContains ?? "" },
                    set: { filters.countryContains = $0.isEmpty ? nil : $0; try? Store.shared.context.save() }
                ))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }

            LabeledContent("Camera contains") {
                TextField("any", text: Binding(
                    get: { filters.cameraContains ?? "" },
                    set: { filters.cameraContains = $0.isEmpty ? nil : $0; try? Store.shared.context.save() }
                ))
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            }

            LabeledContent("Excluded tags") {
                HStack(spacing: 8) {
                    TextField("e.g. portrait", text: $newExclusion)
                        .onSubmit { addExclusion() }
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                    Button("Add") { addExclusion() }
                        .buttonStyle(.glass)
                        .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !filters.excludedTags.isEmpty {
                ForEach(filters.excludedTags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Button(role: .destructive) { removeExclusion(tag) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Running", value: engine.isRunning ? "Yes" : "No")
            if let next = engine.nextFireAt {
                LabeledContent("Next rotation", value: formatNextFire(next))
            }
            if let err = engine.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button("Rotate now") {
                Task { await engine.rotateNow() }
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Helpers

    private func formatMinuteOfDay(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    private func formatNextFire(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        let formatter = DateFormatter()
        formatter.dateFormat = seconds > 86400 ? "EEE HH:mm" : "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func addTopic() {
        let t = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !filters.topics.contains(t) {
            filters.topics.append(t)
            try? Store.shared.context.save()
        }
        newTopic = ""
    }

    private func removeTopic(_ topic: String) {
        filters.topics.removeAll { $0 == topic }
        try? Store.shared.context.save()
    }

    private func addExclusion() {
        let t = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !filters.excludedTags.contains(t) {
            filters.excludedTags.append(t)
            try? Store.shared.context.save()
        }
        newExclusion = ""
    }

    private func removeExclusion(_ tag: String) {
        filters.excludedTags.removeAll { $0 == tag }
        try? Store.shared.context.save()
    }
}

enum IntervalUnit {
    case seconds, minutes, hours
    var toSeconds: Int {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        }
    }
}

struct IntervalPreset: Hashable, Identifiable {
    let label: String
    let seconds: Int
    var id: Int { seconds }
}

/// Type-erased primitive button style so conditional expressions stay well-typed.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let _makeBody: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        self._makeBody = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}

#Preview {
    RotationView()
        .modelContainer(Store.shared.container)
        .frame(width: 720, height: 600)
}
