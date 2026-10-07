import Foundation

/// GF of chain `vdtpfuzz`: a mechanical I/O seam for `Tools/tailcheck/differential_fuzz.py`.
/// Flag `--tailcheck-fuzz-io <in.json> <out.json>`. Reads a file in the same shape as
/// `Tools/tailcheck/parity-fixture.json` (`trigger_cases[]`/`accept_cut_cases[]`), runs each case
/// through `TailCheck.trigger`/`TailCheck.acceptCut`, and writes the actual results keyed by label.
/// It never compares against an expected value and never judges pass/fail -- that comparison is the
/// Python side's job, so a Unicode mismatch is caught by `verify.sh`, not by a judge re-generating
/// cases by hand. Exits nonzero only on a file I/O or JSON error, never on a semantic mismatch.
///
/// The Decodable input structs below are near-identical copies of `TailCheckSelfTest`'s private
/// `SegmentJSON`/`TriggerCase`/`AcceptCutCase` (that file is PROTECTED and stays untouched); any
/// `expected_*` fields present in the input (because the fixture schema carries them) are simply not
/// declared here, so `JSONDecoder` ignores them.
enum TailCheckFuzzIO {
    private struct SegmentJSON: Decodable {
        let start: Double
        let end: Double
        let rawText: String
        let noSpeechProb: Double
        let avgLogprob: Double
        let compressionRatio: Double

        enum CodingKeys: String, CodingKey {
            case start, end
            case rawText = "raw_text"
            case noSpeechProb = "no_speech_prob"
            case avgLogprob = "avg_logprob"
            case compressionRatio = "compression_ratio"
        }

        var asTailCheckSegment: TailCheck.Segment {
            TailCheck.Segment(start: start, end: end, rawText: rawText,
                              noSpeechProb: noSpeechProb, avgLogprob: avgLogprob,
                              compressionRatio: compressionRatio)
        }
    }

    private struct TriggerCaseIn: Decodable {
        let label: String
        let segments: [SegmentJSON]
        let rawText: String
        let finalText: String

        enum CodingKeys: String, CodingKey {
            case label, segments
            case rawText = "raw_text"
            case finalText = "final_text"
        }
    }

    private struct AcceptCutCaseIn: Decodable {
        let label: String
        let text: String
        let junkSuffix: String
        let boundaries: [Int]?
        let maxWords: Int
        let maxShare: Double

        enum CodingKeys: String, CodingKey {
            case label, text
            case junkSuffix = "junk_suffix"
            case boundaries
            case maxWords = "max_words"
            case maxShare = "max_share"
        }
    }

    private struct FuzzInput: Decodable {
        let schema: String
        let triggerCases: [TriggerCaseIn]
        let acceptCutCases: [AcceptCutCaseIn]

        enum CodingKeys: String, CodingKey {
            case schema
            case triggerCases = "trigger_cases"
            case acceptCutCases = "accept_cut_cases"
        }
    }

    private struct TriggerResult: Encodable {
        let label: String
        let reasonsSorted: [String]

        enum CodingKeys: String, CodingKey {
            case label
            case reasonsSorted = "reasons_sorted"
        }
    }

    private struct AcceptCutResult: Encodable {
        let label: String
        let accepted: Bool
        let reason: String
    }

    private struct FuzzOutput: Encodable {
        let schema: String
        let triggerResults: [TriggerResult]
        let acceptCutResults: [AcceptCutResult]

        enum CodingKeys: String, CodingKey {
            case schema
            case triggerResults = "trigger_results"
            case acceptCutResults = "accept_cut_results"
        }
    }

    /// Returns a process exit code: 0 on a clean run, nonzero only on a file I/O or JSON error.
    static func run(inPath: String, outPath: String) -> Int32 {
        let inURL = URL(fileURLWithPath: inPath)
        guard let data = try? Data(contentsOf: inURL) else {
            FileHandle.standardError.write(Data("[tailcheck-fuzz-io] could not read \(inPath)\n".utf8))
            return 1
        }
        let input: FuzzInput
        do {
            input = try JSONDecoder().decode(FuzzInput.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("[tailcheck-fuzz-io] could not decode \(inPath): \(error)\n".utf8))
            return 1
        }

        let triggerResults = input.triggerCases.map { c -> TriggerResult in
            let segments = c.segments.map(\.asTailCheckSegment)
            let reasons = TailCheck.trigger(segments: segments, rawText: c.rawText, finalText: c.finalText)
            return TriggerResult(label: c.label, reasonsSorted: reasons.sorted())
        }

        let acceptCutResults = input.acceptCutCases.map { c -> AcceptCutResult in
            let (accepted, reason) = TailCheck.acceptCut(
                text: c.text, junkSuffix: c.junkSuffix, boundaries: c.boundaries,
                maxWords: c.maxWords, maxShare: c.maxShare)
            return AcceptCutResult(label: c.label, accepted: accepted, reason: reason)
        }

        let output = FuzzOutput(schema: "fuzz-io/1", triggerResults: triggerResults, acceptCutResults: acceptCutResults)

        let encoder = JSONEncoder()
        let outData: Data
        do {
            outData = try encoder.encode(output)
        } catch {
            FileHandle.standardError.write(Data("[tailcheck-fuzz-io] could not encode output: \(error)\n".utf8))
            return 1
        }

        do {
            try outData.write(to: URL(fileURLWithPath: outPath))
        } catch {
            FileHandle.standardError.write(Data("[tailcheck-fuzz-io] could not write \(outPath): \(error)\n".utf8))
            return 1
        }

        return 0
    }
}
