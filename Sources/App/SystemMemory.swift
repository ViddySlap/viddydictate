import Darwin
import Foundation

/// In-process macOS memory facts and the pure local-model budget math built on them.
///
/// The model budget is intentionally based on the kernel's user-wire ceiling, not total physical
/// memory. A missing kernel fact stays unavailable (`nil`) so callers can fail closed instead of
/// substituting a different denominator. No accessor launches a process or reads a command's output.
enum SystemMemory {
    /// Bytes macOS permits user processes to wire (`vm.global_user_wire_limit`).
    static var userWireLimitBytes: UInt64? {
        sysctlUInt64(named: "vm.global_user_wire_limit")
    }

    /// Bytes macOS reserves outside the user-wire ceiling (`vm.global_no_user_wire_amount`).
    static var noUserWireBytes: UInt64? {
        sysctlUInt64(named: "vm.global_no_user_wire_amount")
    }

    /// Installed physical memory (`hw.memsize`).
    static var physicalBytes: UInt64? {
        sysctlUInt64(named: "hw.memsize")
    }

    /// Current whole-machine wired memory from `HOST_VM_INFO64`.
    ///
    /// `wire_count` is a page count. Multiplying it by the live `vm_page_size` produces bytes and
    /// intentionally includes both user and kernel wired pages; the capacity policy wants that
    /// conservative whole-machine reading.
    static var wiredBytes: UInt64? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let (bytes, overflow) = UInt64(statistics.wire_count)
            .multipliedReportingOverflow(by: UInt64(vm_page_size))
        return overflow ? nil : bytes
    }

    /// Map the slider's visible 0...100 position onto 25...90% of the user-wire ceiling.
    static func realFraction(forSliderPosition position: Double) -> Double {
        0.25 + (position / 100.0) * 0.65
    }

    /// The slider-selected model budget in bytes, or nil when the kernel ceiling is unavailable.
    static func budgetBytes(forSliderPosition position: Double) -> UInt64? {
        guard let limit = userWireLimitBytes else { return nil }
        let bytes = Double(limit) * realFraction(forSliderPosition: position)
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return UInt64(bytes)
    }

    /// Decimal gigabytes rendered to one place, matching the Setup row's `36.1 GB` style.
    static func formatGB(_ bytes: UInt64) -> String {
        String(
            format: "%.1f GB",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(bytes) / 1_000_000_000.0
        )
    }

    private static func sysctlUInt64(named name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = name.withCString { pointer in
            sysctlbyname(pointer, &value, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<UInt64>.size else { return nil }
        return value
    }
}
