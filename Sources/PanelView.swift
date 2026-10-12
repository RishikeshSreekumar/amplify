import SwiftUI

/// The popover shown from the menu bar icon.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @AppStorage("ui.showEffects") private var showEffects = true
    @AppStorage("ui.showEQ") private var showEQ = false
    @AppStorage("ui.showApps") private var showApps = false
    @AppStorage("ui.showSettings") private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.error, !model.isOn {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 6)
            }
            if model.permissionDenied {
                Button("Allow System Audio Recording…") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                    .buttonStyle(.link).font(.caption).padding(.top, 6)
            }
            MeterView(meters: model.meters, isOn: model.isOn).padding(.vertical, 12)
            boost
            Divider().padding(.top, 12)
            Section(title: "Effects", systemImage: "sparkles", expanded: $showEffects) { effects }
            Divider()
            Section(title: "Equalizer", systemImage: "slider.vertical.3", expanded: $showEQ) { equalizer }
            Divider()
            Section(title: "Apps", systemImage: "square.grid.2x2", expanded: $showApps) { apps }
            Divider()
            Section(title: "Settings", systemImage: "gearshape", expanded: $showSettings) { settings }
            Divider()
            footer.padding(.top, 10)
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Amplify").font(.headline)
                Text(model.output?.name ?? "No output device")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setOn($0) }))
                .toggleStyle(.switch).labelsHidden()
        }
    }

    private var boost: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Boost")
                Spacer()
                Text("\(model.percent)%").monospacedDigit().fontWeight(.semibold)
            }
            Slider(value: Binding(get: { Double(model.percent) },
                                  set: { model.percent = Int(($0 / 5).rounded()) * 5 }),
                   in: Double(AppModel.percentRange.lowerBound)...Double(AppModel.percentRange.upperBound))
            HStack(spacing: 6) {
                ForEach(AppModel.presets, id: \.self) { p in
                    Button("\(p)%") { model.pickPreset(p) }
                        .buttonStyle(PresetStyle(selected: model.isOn && model.percent == p))
                }
            }
        }
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 10) {
            EffectToggle(title: "Loudness", detail: "Lifts quiet parts, tames loud ones", isOn: $model.loudness)
            EffectToggle(title: "Voice Clarity", detail: "Clearer speech for calls and podcasts", isOn: $model.clarity)
            EffectToggle(title: "Auto-Level", detail: "Evens out volume between videos and apps", isOn: $model.autoLevel)
            EffectToggle(title: "Virtual Bass", detail: "Fuller bass on small speakers", isOn: $model.bassEnabled)
            if model.bassEnabled {
                LabeledSlider(label: "Amount", value: $model.bassAmount, range: 0.1...1,
                              text: "\(Int(model.bassAmount * 100))%")
            }
            EffectToggle(title: "Mono", detail: "Same sound in both ears", isOn: $model.mono)
            LabeledSlider(label: "Width", value: $model.width, range: 0...2, text: widthText)
                .disabled(model.mono)
            LabeledSlider(label: "Balance", value: Binding(get: { model.balance },
                                                           set: { model.balance = abs($0) < 0.05 ? 0 : $0 }),
                          range: -1...1, text: balanceText)
        }
        .padding(.bottom, 10)
    }

    private var widthText: String {
        model.mono ? "Mono" : model.width < 0.95 ? "Narrow" : model.width > 1.05 ? "Wide" : "Normal"
    }

    private var balanceText: String {
        let b = Int((model.balance * 100).rounded())
        return b == 0 ? "Centre" : b < 0 ? "L \(-b)" : "R \(b)"
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $model.eqPreset) {
                    ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Button("Reset") { model.resetEQ() }.controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<EQ.bandCount, id: \.self) { i in
                    VStack(spacing: 4) {
                        Text(String(format: "%+.0f", model.eqGains[i]))
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                        VerticalSlider(value: Binding(get: { model.eqGains[i] }, set: { model.setBand(i, $0) }),
                                       range: Double(-EQ.maxGain)...Double(EQ.maxGain))
                            .frame(height: 100)
                        Text(bandLabel(i)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func bandLabel(_ i: Int) -> String {
        let f = Int(EQ.frequencies[i])
        return f >= 1000 ? "\(f / 1000)k" : "\(f)"
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mixer.isEmpty {
                Text("No apps are using audio.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.mixer) { row in AppRow(model: model, row: row) }
                }
            }
            .frame(maxHeight: 230)
            .fixedSize(horizontal: false, vertical: model.mixer.count <= 6)
            Text("Changing which apps have their own level briefly interrupts audio.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.bottom, 10)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            EffectToggle(title: "Volume keys go past 100%",
                         detail: "At full volume, Volume Up raises the boost. Needs Accessibility permission.",
                         isOn: $model.volumeKeys)
            EffectToggle(title: "Remember boost per output",
                         detail: "Speakers, headphones and AirPods each keep their own level",
                         isOn: $model.rememberPerDevice)
            EffectToggle(title: "Open at Login", detail: nil,
                         isOn: Binding(get: { model.openAtLogin }, set: { model.openAtLogin = $0 }))
        }
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Text("Amplify \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}

// MARK: - Components

private struct Section<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack {
                    Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
            if expanded { content() }
        }
    }
}

private struct EffectToggle: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: $value, in: range).controlSize(.small)
            Text(text).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }
}

private struct PresetStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let y = (1 - (value - range.lowerBound) / span) * h
            let mid = h / 2
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 4)
                Rectangle().fill(Color.accentColor).frame(width: 4, height: abs(y - mid)).offset(y: min(y, mid))
                Rectangle().fill(Color.primary.opacity(0.3)).frame(width: 10, height: 1).offset(y: mid)
                Circle().fill(Color.white).shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 12, height: 12).offset(y: y - 6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let position = Double(min(max(g.location.y / h, 0), 1))
                let v: Double = range.lowerBound + (1 - position) * span
                value = v.rounded()
            })
        }
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let row: AppModel.MixerRow

    var body: some View {
        let percent = model.appPercent(row.bundleID)
        HStack(spacing: 8) {
            Image(nsImage: row.icon).resizable().frame(width: 20, height: 20)
                .opacity(row.isRunning ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(row.name).font(.caption).lineLimit(1)
                    if row.isPlaying {
                        Image(systemName: "waveform").font(.system(size: 8)).foregroundStyle(.green)
                    }
                }
                Slider(value: Binding(get: { Double(percent) }, set: { model.setAppPercent(row.bundleID, Int($0)) }),
                       in: Double(AppModel.appPercentRange.lowerBound)...Double(AppModel.appPercentRange.upperBound))
                    .controlSize(.mini)
            }
            Text(percent == 0 ? "Muted" : "\(percent)%")
                .font(.caption).monospacedDigit().foregroundStyle(percent == 100 ? .secondary : .primary)
                .frame(width: 44, alignment: .trailing)
            Button {
                model.setAppPercent(row.bundleID, 100)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to 100%")
            .opacity(percent == 100 ? 0 : 1)
            .disabled(percent == 100)
        }
    }
}

private struct MeterView: View {
    @ObservedObject var meters: AppModel.Meters
    let isOn: Bool

    var body: some View {
        let meter = meters.value
        return VStack(alignment: .leading, spacing: 4) {
            bar("In", meter.input)
            bar("Out", meter.output)
            HStack {
                Spacer()
                let db = 20 * log10(Double(max(meter.reduction, 0.0001)))
                Text(isOn ? (db < -0.5 ? String(format: "Limiter %.1f dB", db) : "Limiter idle") : "Off")
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(db < -6 ? Color.orange : Color.secondary)
            }
        }
    }

    private func bar(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            GeometryReader { geo in
                let db = 20 * log10(Double(max(level, 0.000_001)))
                let fraction = min(max((db + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * fraction) }
                }
            }
            .frame(height: 5)
        }
    }
}
