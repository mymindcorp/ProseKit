#if canImport(UIKit)
import XCTest
@testable import EditorSyntax

/// Accuracy of content-based language detection over ``DetectionCorpus``.
///
/// The detector is a weighted heuristic and will not score 100% — the value
/// here is that its accuracy is a measured number with a floor under it, so a
/// change to how detection works has to hold the line rather than quietly
/// trading one language's samples for another's.
@MainActor
final class DetectionCorpusTests: XCTestCase {
    private struct Report {
        var hit: [String] = []            // labelled, guessed right, confident
        var timid: [String] = []          // labelled, right or nil, but not confident
        var wrong: [String] = []          // labelled, confidently guessed something else
        var falsePositive: [String] = []  // ambiguous, but confidently guessed
        var quiet: [String] = []          // ambiguous, correctly not confident
    }

    private func evaluate(_ detector: (String) -> LanguageGuess? = { guessLanguage($0) }) -> Report {
        var report = Report()
        for sample in DetectionCorpus.samples {
            let guess = detector(sample.code)
            let confident = guess?.confident ?? false
            switch sample.language {
            case let expected?:
                if confident && guess?.language == expected { report.hit.append(sample.name) }
                else if confident { report.wrong.append("\(sample.name) -> \(guess!.language)") }
                else { report.timid.append(sample.name) }
            case nil:
                if confident { report.falsePositive.append("\(sample.name) -> \(guess!.language)") }
                else { report.quiet.append(sample.name) }
            }
        }
        return report
    }

    func testCorpusAccuracy() {
        let report = evaluate()
        let labelled = report.hit.count + report.timid.count + report.wrong.count
        let accuracy = Double(report.hit.count) / Double(labelled)
        print(unsafe "CORPUS labelled=\(labelled) hit=\(report.hit.count) "
            + "timid=\(report.timid.count) wrong=\(report.wrong.count) "
            + "accuracy=\(String(format: "%.1f", accuracy * 100))%")
        if !report.timid.isEmpty { print("CORPUS timid: \(report.timid.joined(separator: ", "))") }
        if !report.wrong.isEmpty { print("CORPUS wrong: \(report.wrong.joined(separator: ", "))") }
        if !report.falsePositive.isEmpty {
            print("CORPUS false-positive: \(report.falsePositive.joined(separator: ", "))")
        }

        // Floors from the measured baseline: 118/134 hit, no ambiguous sample
        // detected, and one confident miss:
        //
        //   js/switch -> python  (`case "a":` lines look like Python's
        //                         trailing-colon block syntax)
        //
        // Raise these floors when detection genuinely improves; never lower
        // them to make a change pass. The accuracy floor leaves one sample of
        // slack because ties in the score table break on Dictionary iteration
        // order, which is not stable across processes.
        XCTAssertGreaterThanOrEqual(accuracy, 0.87, "detection accuracy regressed")
        XCTAssertLessThanOrEqual(report.wrong.count, 1,
                                 "too many samples confidently detected as the wrong language")
        XCTAssertEqual(report.falsePositive.count, 0,
                       "ambiguous text is being detected confidently")
    }

    /// Per-language floor: accuracy shouldn't be propped up by a few languages
    /// scoring perfectly while another is never recognised at all.
    func testEveryLanguageIsDetectedAtLeastOnce() {
        var detected: Set<CodeLanguage> = []
        for sample in DetectionCorpus.samples {
            guard let expected = sample.language, let guess = guessLanguage(sample.code),
                  guess.confident, guess.language == expected else { continue }
            detected.insert(expected)
        }
        let missing = CodeLanguage.allCases.filter { !detected.contains($0) }
        XCTAssertTrue(missing.isEmpty,
                      "no sample was confidently detected for: \(missing.map(\.rawValue))")
    }
}
#endif
