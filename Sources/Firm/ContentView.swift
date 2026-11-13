import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: PressureEngine
    @State private var permissions = Permissions.status

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Toggle("Enable pen pressure", isOn: $engine.isEnabled)
                .toggleStyle(.switch)
            Toggle("Suppress Force Click (events)", isOn: $engine.suppressForceClick)
                .toggleStyle(.checkbox)
                .help("Swallows stage-2 force-click events so Look Up / Quick Look don't fire mid-stroke.")
            Toggle("Disable trackpad force response (hardware, experimental)", isOn: $engine.hardwareForceOff)
                .toggleStyle(.checkbox)
                .help("Uses MTDeviceSetSystemForceResponseEnabled. On some firmware this disables ALL clicks. Restored automatically when disabled or on quit.")

            Divider()
            Text("Pressure mapping").font(.caption).foregroundStyle(.secondary)
            LabeledSlider(title: "Max force", value: $engine.maxForce, range: 50...1000, format: "%.0f g")
            LabeledSlider(title: "Deadzone", value: $engine.deadzone, range: 0...200, format: "%.0f g")
            LabeledSlider(title: "Curve", value: $engine.gamma, range: 0.3...3.0, format: "γ %.2f")
            LabeledSlider(title: "Minimum", value: $engine.minPressure, range: 0...0.5, format: "%.2f")

            Divider()
            liveMeter
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { permissions = Permissions.status }
    }

    private var header: some View {
        HStack {
            Image(systemName: "pencil.tip.crop.circle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 0) {
                Text("Firm").font(.headline)
                Text(engine.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var liveMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Live pressure").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f · %.0f g · %d touch", engine.livePressure, engine.liveGrams, engine.liveTouches))
                    .font(.caption.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tint)
                        .frame(width: geo.size.width * engine.livePressure)
                        .animation(.linear(duration: 0.03), value: engine.livePressure)
                }
            }
            .frame(height: 8)
            Text(engine.diagnostics)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !permissions.accessibility || !permissions.inputMonitoring {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Permissions needed").font(.caption)
                    Spacer()
                    if !permissions.accessibility {
                        Button("Accessibility") { Permissions.openAccessibilitySettings() }
                            .controlSize(.small)
                    }
                    if !permissions.inputMonitoring {
                        Button("Input Monitoring") { Permissions.openInputMonitoringSettings() }
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Button("Refresh permissions") { permissions = Permissions.status }
                    .controlSize(.small)
                Spacer()
                Button("Quit") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut("q")
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading).font(.callout)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
    }
}
