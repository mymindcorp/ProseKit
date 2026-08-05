import Foundation
import EditorSyntax
import TestHarness

// Content-based language detection is Foundation-only, so it is tested here
// rather than in the iOS `EditorUIKitTests` target: nothing about scoring a
// snippet needs a simulator. The tokenizer and its colours do need UIKit and
// stay over there.

let collector = TestCollector()
func test(_ name: String, _ body: @escaping @Sendable () throws -> Void) { collector.test(name, body) }

registerDetectionTests()
registerAccuracyTests()
registerVocabularyTests()

TestSuite.main("EditorSyntaxTests", collector.all)
