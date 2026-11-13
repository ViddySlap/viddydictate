import Foundation

// VDASK-2: the app-type glue for the review call. Not wired to takes: nothing calls `live` yet.

extension AskBackLevel {
    init(_ level: CleanupLevel) {
        switch level {
        case .cleanup: self = .cleanup
        case .tighten: self = .tighten
        case .summarize: self = .summarize
        }
    }
}

extension AskBackProvider {
    init(_ provider: LLMProvider) {
        switch provider {
        case .local: self = .local
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }
}

extension AskBackReviewRunner {
    /// A runner that sends the review through `TextTransformClient.complete` on the resolved provider
    /// (with the fixed review model) and times out on the main queue after the cloud default, 90 s.
    static func live(resolution: LLMRouteResolution,
                     timeout: TimeInterval = CloudCleanupClient.defaultTimeout,
                     deliver: @escaping Deliver) -> AskBackReviewRunner {
        AskBackReviewRunner(
            timeout: timeout,
            schedule: { after, fire in
                let item = DispatchWorkItem(block: fire)
                DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
                return { item.cancel() }
            },
            provider: { system, input, completion in
                TextTransformClient.complete(system: system, input: input,
                                             resolution: resolution, timeout: timeout) { result in
                    switch result {
                    case .ok(let text): completion(.text(text))
                    case .timedOut: completion(.timedOut)
                    case .unavailable(let why): completion(.failed(why))
                    case .badOutput(let why): completion(.failed(why))
                    }
                }
            },
            deliver: deliver)
    }
}
