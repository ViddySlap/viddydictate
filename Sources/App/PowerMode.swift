import Foundation
import IOKit.ps

/// Manual, sticky transcription/presentation behavior. Provider and model routing never consult this value.
enum PowerMode: String, Codable, CaseIterable {
    case live
    case finalOnly

    /// Live mode refreshes the growing transcript while the take is held. Final-only omits those repeated
    /// snapshot passes; both modes still perform exactly one final STT pass when the take is released.
    var partialTranscriptionInterval: TimeInterval? {
        switch self {
        case .live:      return 0.7
        case .finalOnly: return nil
        }
    }

    static let finalTranscriptionPassCount = 1
    var usesCompactHUD: Bool { self == .finalOnly }
    var label: String { self == .live ? "Live" : "Final-only" }
}

/// A value-only input to the battery advisory policy. Runtime battery APIs are isolated in
/// `SystemBatteryReader`; tests exercise the policy with synthetic values only.
struct BatterySnapshot: Equatable {
    let isPluggedIn: Bool?
    let percentage: Int?
    let macOSLowPowerMode: Bool
}

/// Only eligibility-relevant changes are material. A one-percent drain inside the same threshold band
/// does not nag again; plug/unplug, crossing 30%, or changing macOS Low Power Mode does.
struct BatteryAdvisoryMaterialState: Equatable, Codable {
    enum PowerSource: String, Codable { case pluggedIn, unplugged, unknown }
    enum ChargeBand: String, Codable { case aboveThreshold, atOrBelowThreshold, unknown }

    let powerSource: PowerSource
    let chargeBand: ChargeBand
    let macOSLowPowerMode: Bool
}

enum BatteryAdvisoryReason: Equatable {
    case lowBattery
    case macOSLowPowerMode
    case lowBatteryAndMacOSLowPowerMode

    var message: String {
        switch self {
        case .lowBattery:
            return "Battery is at 30% or below — try Final-only, or open Models in Settings."
        case .macOSLowPowerMode:
            return "macOS Low Power Mode is on — try Final-only, or open Models in Settings."
        case .lowBatteryAndMacOSLowPowerMode:
            return "Battery is low and macOS Low Power Mode is on — try Final-only, or open Models in Settings."
        }
    }
}

struct BatteryAdvisoryEvaluation: Equatable {
    let materialState: BatteryAdvisoryMaterialState
    let reason: BatteryAdvisoryReason?
    let shouldSuggest: Bool
    let shouldClearDismissal: Bool
}

enum BatteryAdvisoryPolicy {
    static let thresholdPercentage = 30

    static func evaluate(snapshot: BatterySnapshot, powerMode: PowerMode,
                         dismissedFor: BatteryAdvisoryMaterialState?) -> BatteryAdvisoryEvaluation {
        let state = materialState(for: snapshot)
        let lowBattery = state.powerSource == .unplugged && state.chargeBand == .atOrBelowThreshold
        let reason: BatteryAdvisoryReason?
        switch (lowBattery, snapshot.macOSLowPowerMode) {
        case (true, true):   reason = .lowBatteryAndMacOSLowPowerMode
        case (true, false):  reason = .lowBattery
        case (false, true):  reason = .macOSLowPowerMode
        case (false, false): reason = nil
        }
        let dismissalMatches = dismissedFor == state
        return BatteryAdvisoryEvaluation(
            materialState: state,
            reason: reason,
            shouldSuggest: powerMode == .live && reason != nil && !dismissalMatches,
            shouldClearDismissal: dismissedFor != nil && !dismissalMatches)
    }

    private static func materialState(for snapshot: BatterySnapshot) -> BatteryAdvisoryMaterialState {
        let source: BatteryAdvisoryMaterialState.PowerSource
        switch snapshot.isPluggedIn {
        case true?:  source = .pluggedIn
        case false?: source = .unplugged
        case nil:    source = .unknown
        }

        let band: BatteryAdvisoryMaterialState.ChargeBand
        if let percentage = snapshot.percentage {
            band = percentage <= thresholdPercentage ? .atOrBelowThreshold : .aboveThreshold
        } else {
            band = .unknown
        }
        return BatteryAdvisoryMaterialState(
            powerSource: source, chargeBand: band,
            macOSLowPowerMode: snapshot.macOSLowPowerMode)
    }
}

/// The only runtime bridge to host battery state. It reads the internal battery description and the
/// macOS Low Power flag; no setting is mutated and no provider/model state is involved.
enum SystemBatteryReader {
    static func current() -> BatterySnapshot {
        var pluggedIn: Bool?
        var percentage: Int?

        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            if let state = description[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSACPowerValue { pluggedIn = true }
                else if state == kIOPSBatteryPowerValue { pluggedIn = false }
            }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 {
                percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            }
            break
        }

        return BatterySnapshot(
            isPluggedIn: pluggedIn,
            percentage: percentage,
            macOSLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
