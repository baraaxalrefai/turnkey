import ApplicationServices
import Darwin
import Foundation

/// Window-level focusing the way AltTab and yabai do it. macOS has no public API to make one specific
/// window key without clicking it, so these are looked up at runtime; if any is missing we fall back to
/// public Accessibility calls.
enum PrivateAPI {
    private typealias AXGetWindowFn = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let p = dlsym(handle ?? rtldDefault, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let axGetWindow = sym("_AXUIElementGetWindow", in: nil, as: AXGetWindowFn.self)
    private static let getPSN = sym("GetProcessForPID", in: nil, as: GetPSNFn.self)
    private static let setFront = sym("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontFn.self)
    private static let postRecord = sym("SLPSPostEventRecordTo", in: skyLight, as: PostRecordFn.self)

    static var canFocusWindows: Bool { getPSN != nil && setFront != nil && postRecord != nil }

    /// CGWindowID of an AX window element.
    static func windowID(of el: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid: UInt32 = 0
        let err = fn(UnsafeRawPointer(Unmanaged.passUnretained(el).toOpaque()), &wid)
        return err == 0 && wid != 0 ? wid : nil
    }

    /// Brings `windowID` of `pid` to the front as the key window (no click involved).
    static func focus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getPSN, let setFront, let postRecord else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard getPSN(pid, &psn) == 0 else { return false }
        // 0x200 = kCPSUserGenerated
        guard setFront(&psn, windowID, 0x200) == 0 else { return false }
        // Synthesised "make key window" event records (layout from yabai / Hammerspoon #370).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowID
        withUnsafeBytes(of: &wid) { raw in
            for i in 0..<4 { bytes[0x3c + i] = raw[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postRecord(&psn, $0.baseAddress!) }
        return true
    }
}
