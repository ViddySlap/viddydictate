import Darwin

enum ProcessGroup {
    static func processGroupIsEmpty(_ pid: pid_t) -> Bool {
        errno = 0
        return kill(-pid, 0) != 0 && errno == ESRCH
    }

    static func withCStringArray<R>(_ strings: [String],
                                    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
