import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

// MARK: - Global pause shortcut (⌃⌥⌘G)

final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    static let displayString = "⌃⌥⌘G"

    func register() {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onPress?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5452_4E4B), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { Diagnostics.shared.add("Couldn't register \(Self.displayString) (error \(status))") }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

// MARK: - Lock / sleep

/// The camera stops while the Mac sleeps, the screen is locked, the screen saver runs or you switch user.
final class PowerMonitor {
    private var asleep = false
    private var screensAsleep = false
    private var locked = false
    private var screenSaver = false
    private var sessionInactive = false
    private var tokens: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    var isSystemPaused: Bool { asleep || screensAsleep || locked || screenSaver || sessionInactive }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping () -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                body()
                self?.onChange?()
            })
        }
        on(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.asleep = true }
        on(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.asleep = false }
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screensAsleep = true }
        on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screensAsleep = false }
        on(ws, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionInactive = true }
        on(ws, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionInactive = false }
        let dnc = DistributedNotificationCenter.default()
        on(dnc, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.locked = true }
        on(dnc, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.locked = false }
        on(dnc, Notification.Name("com.apple.screensaver.didstart")) { [weak self] in self?.screenSaver = true }
        on(dnc, Notification.Name("com.apple.screensaver.didstop")) { [weak self] in self?.screenSaver = false }
    }
}

// MARK: - Permissions

enum Permissions {
    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestCamera(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    static func openAccessibilitySettings() {
        _ = AX.isTrusted(prompt: true)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openLoginItemsSettings() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Start at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on, service.status != .enabled {
                try service.register()
                Diagnostics.shared.add("Start at login: on")
            } else if !on, service.status == .enabled {
                try service.unregister()
                Diagnostics.shared.add("Start at login: off")
            }
        } catch {
            Diagnostics.shared.add("Start at login failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Notifications ("time to recalibrate")

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onRecalibrate: (() -> Void)?

    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let action = UNNotificationAction(identifier: "recalibrate", title: "Recalibrate", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "drift", actions: [action],
                                                                 intentIdentifiers: [], options: [])])
    }

    func notifyDrift(screenName: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Turnkey keeps missing on \(screenName)"
            content.body = "Focus keeps landing on the wrong screen. If a screen or your chair moved, a quick recalibration fixes it."
            content.categoryIdentifier = "drift"
            center.add(UNNotificationRequest(identifier: "drift-\(screenName)", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onRecalibrate?() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
