import Foundation
import EditorSyntax
import TestHarness

// Verdicts pinned against mutants of the detection scanner that the corpus
// let through. The corpus measures accuracy in aggregate, so a signal that
// only decides a handful of its samples can drift without moving the floor;
// each snippet here sits right at the margin one signal decides — a winner
// exactly two points clear, or a guess one point from confidence.

private func expectGuess(_ code: String, _ language: CodeLanguage, confident: Bool,
                         file: StaticString = #file, line: UInt = #line) throws {
    let guess = guessLanguage(code)
    try expectEqual(guess?.language, language, "language of \(code.debugDescription)", file: file, line: line)
    try expectEqual(guess?.confident, confident, "confidence of \(code.debugDescription)", file: file, line: line)
}

func registerSyntaxMutationKillTests() {
    test("syntax kills: four-letter SQL keywords count") {
        // `from` is one of the two keywords SQL needs to score at all.
        try expectGuess("select name from people", .sql, confident: true)
    }

    test("syntax kills: a single SQL keyword used as a name doesn't score SQL") {
        // Two JavaScript words and a `let`: three points, and `select` alone
        // must not give SQL the two that would make it a contest.
        try expectGuess("const a = select(1); let b = a; console.log(b);", .javascript, confident: true)
    }

    test("syntax kills: a truncated property accessor is scanned safely") {
        // `get; set` with nothing after it — the scan looks one byte past
        // `set` for its semicolon, and must not read past the end to do so.
        try expectNil(guessLanguage("public string Name { get; set"))
    }

    test("syntax kills: a lowercase element type isn't a Java array declaration") {
        // C# writes `string[]`; only the capitalised `String[]` scores Java.
        try expectGuess("String[] names = { \"a\" };\nstring[] parts = line.Split(',');\nConsole.WriteLine(parts.Length);",
                        .csharp, confident: true)
    }

    test("syntax kills: a string left open at the end of a line is not a JSON key") {
        // The quote before `multi` never closes on its line, so nothing here
        // is a key — JSON gets only its opening-bracket points.
        try expectGuess("[\"multi\nline\": 1]", .json, confident: false)
    }

    test("syntax kills: semicolons after a type annotation aren't CSS declarations") {
        // `i: number = 0;` is one declaration shape; the loop condition's
        // semicolon after it on the same line is not a second.
        try expectGuess("for (let i: number = 0; i < n; i++) {\n  total += i;\n}", .typescript, confident: false)
    }

    test("syntax kills: the short echo tag opens PHP") {
        try expectGuess("<?= $title ?>", .php, confident: true)
    }

    test("syntax kills: a generic after a digit-ended type name is not a tag") {
        // `Tuple2<Int>` — the `<` follows an identifier character (a digit), so
        // it's a type argument, not markup.
        try expectGuess("fun pair(): Tuple2<Int> = Tuple2<Int>(1)", .kotlin, confident: true)
    }

    test("syntax kills: an uppercase DOCTYPE is still a doctype") {
        try expectGuess("<!DOCTYPE html>", .html, confident: true)
        try expectGuess("<!doctype html>", .html, confident: true)
    }

    test("syntax kills: a tag may break its attributes onto the next line") {
        try expectGuess("<div\n  id=\"card\">\n</div>", .html, confident: true)
    }

    test("syntax kills: one C++-only signal is enough to make C code C++") {
        // `nullptr` is the only thing here C doesn't have.
        try expectGuess("#include \"vec.h\"\nint main() { return nullptr == 0; }", .cpp, confident: true)
    }

    test("syntax kills: an arrow function rules out JSON") {
        // It opens with `[` and has no semicolon, but a `=>` is never JSON.
        try expectGuess("[1, 2].map(x => x * 2).forEach(y => console.log(y))", .javascript, confident: true)
    }
}
