import AppKit
import AVFoundation
import SwiftUI

struct SettingsView: View {
    let app: AppDelegate
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralTab(app: app, settings: settings, state: state)
                .tabItem { Label("General", systemImage: "eye") }
            SwitchingTab(settings: settings)
                .tabItem { Label("Switching", systemImage: "arrow.left.arrow.right") }
            ScreensTab(app: app, settings: settings, state: state)
                .tabItem { Label("Screens", systemImage: "display.2") }
            PrivacyTab(state: state)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            DiagnosticsTab(state: state)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(.top, 6)
        .frame(width: 620, height: 600)
    }
}

// MARK: - General

private struct GeneralTab: View {
    let app: AppDelegate
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @State private var cameras: [AVCaptureDevice] = CameraService.cameras()

    private var statusText: String {
        if state.userPaused { return "Paused" }
        if state.systemPaused { return "Paused (locked or asleep)" }
        switch state.live.state {
        case .tracking: return "Facing \(state.live.facingName ?? "—")" + (state.live.waiting.map { " · waiting, \($0)" } ?? "")
        case .away: return "Looking away from the screens"
        case .noFace: return "Can't see your face"
        case .needsCalibration: return "Not calibrated yet"
        case .noCamera: return "Camera unavailable"
        default: return state.cameraAuthorized ? "Off" : "Camera not allowed"
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    FacePreview(points: state.landmarks)
                        .frame(width: 210, height: 130)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(statusText).font(.title3.weight(.semibold))
                        if state.live.faceFound && !state.userPaused {
                            Text(String(format: "Head  yaw %.1f°  ·  pitch %.1f°", state.live.yawDeg, state.live.pitchDeg))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button(state.userPaused ? "Resume" : "Pause") { app.togglePause() }
                            Button("Calibrate…") { app.startCalibration(screenIDs: nil) }
                                .disabled(!state.cameraAuthorized)
                        }
                        Text("Pause / resume from anywhere: \(HotkeyManager.displayString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Camera") {
                Picker("Camera", selection: $settings.cameraID) {
                    Text("Automatic (external if plugged in, else built-in)").tag(String?.none)
                    ForEach(cameras, id: \.uniqueID) { c in
                        Text(c.localizedName).tag(Optional(c.uniqueID))
                    }
                }
                .onAppear { cameras = CameraService.cameras() }
                Text("Pick the camera that looks straight at you. It's read at 720p, 15 frames a second at most.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show gaze dot", isOn: $settings.showGazeDot)
                Toggle("Start at login", isOn: $settings.launchAtLogin)
                Toggle("Pause shortcut \(HotkeyManager.displayString)", isOn: $settings.hotkeyEnabled)
            }

            if !state.axTrusted || !state.cameraAuthorized {
                Section {
                    Button("Open Setup Guide…") { app.showOnboarding() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Switching

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct SwitchingTab: View {
    @ObservedObject var settings: AppSettings

    private func ms(_ v: Double) -> String { "\(Int((v * 1000).rounded())) ms" }
    private func secs(_ v: Double) -> String { String(format: "%.1f s", v) }

    var body: some View {
        Form {
            Section("Timing") {
                SliderRow(title: "Settle on a screen for", value: $settings.config.screenDwell,
                          range: 0.1...1.0, step: 0.05, format: ms)
                SliderRow(title: "Settle on a window or pane for", value: $settings.config.windowDwell,
                          range: 0.2...1.5, step: 0.05, format: ms)
                SliderRow(title: "Reading while typing: wait after the last keystroke", value: $settings.config.typingQuiet,
                          range: 0...5, step: 0.1, format: secs)
                Text("Focus never jumps mid-typing. Stop typing and look somewhere else, and focus follows after the settle time. Keep typing while your eyes are on another screen or pane, for example copying from it, and focus waits until you pause this long. Look straight back without typing, and it snaps back almost instantly.")
                    .font(.caption).foregroundStyle(.secondary)
                SliderRow(title: "Wait after using the mouse or trackpad", value: $settings.config.mouseQuiet,
                          range: 0...4, step: 0.1, format: secs)
            }

            Section {
                SliderRow(title: "Edge stickiness", value: $settings.config.hysteresis,
                          range: 0...5, step: 0.25, format: { String(format: "%.2f", $0) })
                Text("How much farther you must turn to cross back over the edge between two screens, so resting your eyes near the bezel doesn't bounce focus back and forth.")
                    .font(.caption).foregroundStyle(.secondary)
                SliderRow(title: "Still counts as a screen up to", value: $settings.config.awayMargin,
                          range: 0.1...0.6, step: 0.05, format: { "\(Int(($0 * 100).rounded()))% outside it" })
                Text("Anything farther out — your phone, the desk, the window — counts as looking away.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Edges")
            }

            Section("What follows your gaze") {
                Toggle("Move the pointer to the screen you turn to", isOn: $settings.config.movePointer)
                Toggle("Windows on the same screen", isOn: $settings.config.switchWindows)
                Toggle("Split panes in terminals and code editors", isOn: $settings.config.switchPanes)
                Toggle("VS Code, Cursor and Windsurf panes", isOn: $settings.config.electronPanes)
                    .disabled(!settings.config.switchPanes)
                if settings.config.switchPanes && settings.config.electronPanes {
                    Text("This switches on VS Code's accessibility tree. Add \"editor.accessibilitySupport\": \"off\" to VS Code's settings.json so it doesn't offer screen-reader mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Click the middle of a pane when an app refuses other ways", isOn: $settings.config.paneClickFallback)
                    .disabled(!settings.config.switchPanes)
                Text("Only ever in terminals and code editors, in the middle of the pane you're looking at. Browsers, chat and documents are always focused as a whole.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Restore defaults") { settings.resetSwitchingDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Screens

private struct ScreensTab: View {
    let app: AppDelegate
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @State private var confirmDelete = false

    private func bias(_ id: String) -> Binding<Double> {
        Binding(
            get: { settings.config.screenBias[id] ?? 0 },
            set: { settings.config.screenBias[id] = abs($0) < 0.01 ? nil : $0 }
        )
    }

    var body: some View {
        Form {
            Section("Screens") {
                ForEach(state.screenRows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: row.connected ? "display" : "display.trianglebadge.exclamationmark")
                                .foregroundStyle(row.calibrated ? Color.accentColor : Color.orange)
                            Text(row.name).font(.headline)
                            if !row.connected { Text("not connected").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if row.connected {
                                Button(row.calibrated ? "Recalibrate" : "Calibrate") {
                                    app.startCalibration(screenIDs: [row.id])
                                }
                                .disabled(!state.cameraAuthorized || state.calibrating)
                            } else {
                                Button("Forget") { app.forgetScreen(row.id) }
                            }
                        }
                        if row.calibrated {
                            Text("Precision \(row.accuracy) · \(row.samples) samples (\(row.clickSamples) learned from clicks)\(row.calibratedAt.map { " · calibrated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not calibrated").font(.caption).foregroundStyle(.orange)
                        }
                        if row.connected, row.calibrated, state.screenRows.filter({ $0.connected && $0.calibrated }).count > 1 {
                            HStack {
                                Text("Edge bias").font(.caption)
                                Slider(value: bias(row.id), in: -3...3, step: 0.25)
                                Text(String(format: "%+.2f", settings.config.screenBias[row.id] ?? 0))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button("Calibrate all screens…") { app.startCalibration(screenIDs: nil) }
                        .disabled(!state.cameraAuthorized || state.calibrating)
                    Spacer()
                }
                Text("Recalibrate after moving the laptop or a monitor; leaning in or sitting back is handled automatically. Edge bias shifts the boundary between screens: positive lets that screen claim more of the shared edge.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Learning from clicks") {
                Toggle("Learn from my clicks", isOn: $settings.config.learnFromClicks)
                Text("You're almost always looking at what you click, so clicks on the screen you're facing quietly refine the model. If they start disagreeing with it, Turnkey suggests a recalibration.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reset learned data") { app.models.resetLearned() }
                    Spacer()
                    Button("Delete all calibration data…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all calibration data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { app.deleteAllData() }
        } message: {
            Text("You'll need to calibrate again before focus can follow your gaze.")
        }
    }
}

// MARK: - Privacy

private struct PrivacyTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("What happens to the camera") {
                Label("Camera frames are analysed in memory on this Mac by Apple's Vision framework, then released immediately.", systemImage: "cpu")
                Label("Nothing is recorded or written to disk — no photos, no video.", systemImage: "externaldrive.badge.xmark")
                Label("No networking code at all — nothing to sign in to, nothing that phones home. The build script refuses to build if networking code appears.", systemImage: "wifi.slash")
                Label("720p at no more than 15 frames a second (10 for screens only, 4 when nobody is there). The camera stops when you pause, lock the screen or the Mac sleeps.", systemImage: "video")
            }
            Section("This session") {
                LabeledContent("Frames analysed", value: "\(state.framesAnalysed)")
                LabeledContent("Frames saved", value: "0")
                LabeledContent("Data sent anywhere", value: "None")
            }
            Section("Stored on this Mac") {
                Text("~/Library/Application Support/Turnkey/calibration.json holds head-pose numbers from calibration and learned clicks (no images). Settings live in this app's local preferences.")
                    .font(.callout)
                Button("Show in Finder") {
                    let url = ModelStore.fileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(ModelStore.directory.deletingLastPathComponent())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsTab: View {
    @ObservedObject var state: AppState
    @ObservedObject var diagnostics = Diagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Camera").foregroundStyle(.secondary); Text(state.cameraAuthorized ? "Allowed — \(state.cameraName ?? "idle")" : "Not allowed") }
                GridRow { Text("Accessibility").foregroundStyle(.secondary); Text(state.axTrusted ? "Allowed" : "Not allowed") }
                GridRow { Text("Window focus").foregroundStyle(.secondary); Text(state.privateFocusAPI ? "Window-precise (SkyLight)" : "Accessibility fallback") }
                GridRow { Text("Model").foregroundStyle(.secondary); Text(state.hasModel ? "Calibrated" : "Not calibrated") }
            }
            .font(.callout)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: diagnostics.lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.lines.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { diagnostics.clear() }
                Spacer()
                Text("Only kept in memory.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}

// MARK: - Face preview (landmark dots only, never the camera image)

struct FacePreview: View {
    let points: [CGPoint]

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(Color(white: 0.08)))
            guard points.count > 3 else {
                ctx.draw(Text("No face").font(.caption).foregroundColor(.gray),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            // Mirror like a mirror, keep the camera's 16:9 proportions, and fit the face into the box.
            let pts = points.map { CGPoint(x: (1 - $0.x) * 16, y: (1 - $0.y) * 9) }
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
            let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            let s = min(size.width * 0.72 / max(maxX - minX, 1e-3), size.height * 0.8 / max(maxY - minY, 1e-3))
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            for p in pts {
                let px = size.width / 2 + (p.x - cx) * s
                let py = size.height / 2 + (p.y - cy) * s
                ctx.fill(Path(ellipseIn: CGRect(x: px - 1.6, y: py - 1.6, width: 3.2, height: 3.2)),
                         with: .color(.teal))
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("Landmarks only — no image")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }
}
