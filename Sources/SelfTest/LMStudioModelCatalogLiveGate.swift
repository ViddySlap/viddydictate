import Foundation

/// Live S4 gate. It exercises the same `ModelResidency.availableModels` entry point Settings uses.
/// A managed Codex seatbelt cannot reach the shared LM Studio server, so that environment abstains
/// explicitly and unsandboxed release verification runs the real assertion.
enum LMStudioModelCatalogLiveGate {
    static func run() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CODEX_SANDBOX"]?.isEmpty == false
            || environment["CODEX_PERMISSION_PROFILE"]?.isEmpty == false {
            print("[lmstudio-model-catalog-live] [skip] SKIPPED: managed sandbox denies live LM Studio access")
            return true
        }

        guard ModelResidency.isInstalled else {
            print("[lmstudio-model-catalog-live] [skip] SKIPPED: lms CLI is not installed")
            return true
        }
        guard ModelResidency.serverResponds() else {
            print("[lmstudio-model-catalog-live] [skip] SKIPPED: LM Studio is not answering; Settings uses fallback models")
            return true
        }
        guard let available = ModelResidency.availableModels() else {
            print("[lmstudio-model-catalog-live] FAIL: answering LM Studio did not produce a parseable installed-model catalog")
            return false
        }
        guard !available.isEmpty else {
            print("[lmstudio-model-catalog-live] [skip] SKIPPED: LM Studio reports no installed LLM models")
            return true
        }
        let ids = available.map(\.modelID)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            print("[lmstudio-model-catalog-live] FAIL: installed-model catalog contains blank or duplicate model ids")
            return false
        }

        // Note to Handoff's local sanity pass picks its helper out of THIS catalog. A fixture cannot tell
        // us which capability marker the installed LM Studio actually uses, and getting that wrong is
        // silent: the selector returns nil, the feature degrades to filename-only, and every offline gate
        // still passes. So assert the real catalog end to end — if any installed model reports itself as
        // vision-capable, production must be able to select one.
        guard let installed = ModelResidency.availableInstalledModels(), !installed.isEmpty else {
            print("[lmstudio-model-catalog-live] FAIL: installed-model catalog did not re-parse with capability metadata")
            return false
        }
        let capable = installed.filter(\.isVisionCapable)
        if capable.isEmpty {
            print("[lmstudio-model-catalog-live] [skip] SKIPPED vision-helper assertion: "
                  + "no installed model reports vision capability (Note to Handoff is filename-only here)")
        } else {
            guard let helper = LMStudioModelCatalog.smallestVisionModel(in: installed) else {
                print("[lmstudio-model-catalog-live] FAIL: \(capable.count) installed model(s) report vision "
                      + "capability but the Note to Handoff selector chose none — the local sanity pass "
                      + "would silently never run")
                return false
            }
            let smallest = capable.map { $0.sizeBytes ?? Int64.max }.min() ?? Int64.max
            guard (helper.sizeBytes ?? Int64.max) == smallest else {
                print("[lmstudio-model-catalog-live] FAIL: selected vision helper \(helper.modelID) is not the "
                      + "smallest vision-capable installed model")
                return false
            }
            print("[lmstudio-model-catalog-live] vision helper: \(helper.modelID) "
                  + "(smallest of \(capable.count) vision-capable installed models)")
        }

        print("[lmstudio-model-catalog-live] PASS: lms ls returned \(available.count) available LLM models")
        return true
    }
}
