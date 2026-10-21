import SwiftUI

/// First-run guide: camera → Accessibility → calibrate → go.
struct OnboardingView: View {
    let app: AppDelegate
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.teal)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.teal.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turnkey").font(.title2.weight(.bold))
                    Text("Turn your head. Your keys follow.").foregroundStyle(.secondary)
                }
            }

            Text("Turnkey reads which way your head is turned and hands keyboard focus to the screen you're facing, so your first keystroke lands where you're looking. It all happens on this Mac: frames are analysed in memory and discarded, and the app has no network code at all.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            StepRow(number: 1, title: "Allow the camera",
                    detail: "Used only to measure which way your head is turned. Frames stay in memory and are never saved.",
                    done: state.cameraAuthorized) {
                if state.cameraAuthorized {
                    HStack(spacing: 12) {
                        FacePreview(points: state.landmarks)
                            .frame(width: 150, height: 92)
                        Text(state.landmarks.isEmpty ? "Looking for your face…" : "Your face is in view. These dots are all the app keeps from each frame, and only for a moment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    if state.cameraDenied {
                        Button("Open Camera Settings") { Permissions.openCameraSettings() }
                    } else {
                        Button("Allow Camera") { app.requestCamera() }
                    }
                }
            }

            StepRow(number: 2, title: "Allow Accessibility",
                    detail: "Lets Turnkey bring a window forward and move the pointer to the screen you turn to. Switch on “Turnkey” in the list that opens.",
                    done: state.axTrusted) {
                if !state.axTrusted {
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                }
            }

            StepRow(number: 3, title: "Calibrate your screens",
                    detail: "Follow a moving dot around each screen, with extra stops along the edge where two screens meet. About half a minute per screen.",
                    done: state.hasModel) {
                Button(state.hasModel ? "Recalibrate" : "Calibrate Screens") { app.startCalibration(screenIDs: nil) }
                    .disabled(!state.cameraAuthorized || state.calibrating)
            }

            StepRow(number: 4, title: "Turn and type",
                    detail: "Face the screen you want and type. Pause any time with \(HotkeyManager.displayString) or from the eye in the menu bar; while your hand is on the mouse, Turnkey keeps still.",
                    done: false, numbered: true) { EmptyView() }

            Spacer(minLength: 0)

            HStack {
                Toggle("Start at login", isOn: $settings.launchAtLogin)
                Spacer()
                Button("Done") { app.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 600, height: 720)
    }
}

private struct StepRow<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    var numbered = true
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.18))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
                    .padding(.top, 2)
            }
        }
    }
}
