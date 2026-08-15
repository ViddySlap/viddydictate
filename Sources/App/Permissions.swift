import Cocoa
import AVFoundation
import ApplicationServices
import IOKit.hid

/// Microphone authorization as a status question rather than a request. `AVAuthorizationStatus` has
/// four cases but only three outcomes matter to a caller, and `restricted` (MDM policy) is not something
/// the user can turn on, so it reads the same as denied.
enum MicrophoneAuthorization {
    case authorized
    case notDetermined
    case denied
}

/// One-time TCC permission helpers. Accessibility + Input Monitoring grants typically require an
/// app relaunch to take effect; Microphone takes effect immediately.
enum Permissions {
    /// Read the microphone grant WITHOUT requesting it. `microphone(_:)` below requests access when the
    /// status is undetermined, which is right at first use and wrong for a status check: a preflight that
    /// prompts is not a preflight.
    static func microphoneAuthorization() -> MicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    @discardableResult
    static func accessibility(prompt: Bool) -> Bool {
        // Key literal avoids SDK-version differences in how kAXTrustedCheckOptionPrompt imports.
        let opts: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    @discardableResult
    static func inputMonitoring(prompt: Bool) -> Bool {
        let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !granted && prompt { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        return granted
    }

    static func microphone(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }
}
