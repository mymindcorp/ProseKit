import Foundation
import DocumentModel
import EditorSerialization
import TestHarness

// A content-preservation property for HTML we did not write.
//
// The serialization sweep round-trips our own output, and the foreign-markup
// fuzzer throws tag soup at the parser and asks only for a valid document or an
// error. Neither asks the question a person pasting from Google Docs asks: did
// all my words arrive? The importers' content-loss bugs — a paragraph after a
// figure's caption, a sub-list written straight inside a task list, a table
// cell the schema couldn't hold — were each a valid document with text missing
// from it, which a validity check alone waves through.
//
// So: a corpus shaped like what real editors put on the clipboard, parsed into
// the test schema and into that schema narrowed one rule at a time (a host's
// schema is an ordinary configuration, and every narrowing is a place where the
// fitting code has to find somewhere else for the content). For each pair:
//
// 1. `parse` returns a document that passes its own `check()`. It is allowed to
//    throw `nestingTooDeep`, which none of these approach, and its
//    `invalidDocument` error documents itself as "a bug rather than bad
//    input" — so for markup this ordinary a throw is a failure, not a pass.
// 2. Every visible word of the source appears in the document's text, in
//    order. Visible means outside `<script>`, `<style>`, `<template>`,
//    `<head>`, `<math>` (which becomes a formula attribute, not text) and any
//    `aria-hidden="true"` element. Words, because the parser keeps whitespace
//    as written and a document spells a block boundary as a boundary rather
//    than a space: comparing word sequences is what makes "two paragraphs
//    glued into one word" a failure while leaving whitespace to the parser.

// MARK: - Narrowed schemas

/// The test schema with one rule changed, keeping the declaration order (which
/// decides the default block type, and so what `fitContent` fills in with).
private func narrowed(content: [String: String] = [:], marks: [String: String] = [:],
                      droppingNodes dropped: Set<String> = [], droppingMarks droppedMarks: Set<String> = []) throws -> Schema {
    var specs: [(String, NodeSpec)] = []
    for name in schema.nodeSpecOrder where !dropped.contains(name) {
        guard var s = schema.nodes[name]?.spec else { continue }
        if let c = content[name] { s.content = c }
        if let m = marks[name] { s.marks = m }
        // A node whose content names a dropped type goes with it.
        if let c = s.content,
           dropped.contains(where: { c.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }) {
            continue
        }
        specs.append((name, s))
    }
    var markSpecs: [(String, MarkSpec)] = []
    for name in schema.markSpecOrder where !droppedMarks.contains(name) {
        if let m = schema.marks[name] { markSpecs.append((name, m.spec)) }
    }
    return try Schema(nodes: specs, marks: markSpecs, topNode: "doc")
}

private func importSchemas() throws -> [(String, Schema)] {
    [
        ("full", schema),
        // Content narrowed one rule at a time.
        ("doc: paragraph+", try narrowed(content: ["doc": "paragraph+"])),
        ("blockquote: paragraph+", try narrowed(content: ["blockquote": "paragraph+"])),
        ("listItem: paragraph", try narrowed(content: ["listItem": "paragraph"])),
        ("listItem: paragraph+", try narrowed(content: ["listItem": "paragraph+"])),
        ("taskItem: paragraph", try narrowed(content: ["taskItem": "paragraph"])),
        ("tableCell: paragraph", try narrowed(content: ["tableCell": "paragraph"])),
        ("tableHeader: paragraph", try narrowed(content: ["tableHeader": "paragraph"])),
        ("tableRow: tableCell+", try narrowed(content: ["tableRow": "tableCell+"])),
        ("figure: paragraph+ figcaption?", try narrowed(content: ["figure": "paragraph+ figcaption?"])),
        ("figure: block+ figcaption", try narrowed(content: ["figure": "block+ figcaption"])),
        ("detailsContent: paragraph+", try narrowed(content: ["detailsContent": "paragraph+"])),
        ("detailsSummary: text*", try narrowed(content: ["detailsSummary": "text*"])),
        ("heading: text*", try narrowed(content: ["heading": "text*"])),
        ("paragraph: text*", try narrowed(content: ["paragraph": "text*"])),
        // Marks narrowed.
        ("heading marks \"\"", try narrowed(marks: ["heading": ""])),
        ("paragraph marks bold", try narrowed(marks: ["paragraph": "bold"])),
        ("paragraph marks \"\"", try narrowed(marks: ["paragraph": ""])),
        ("figcaption marks \"\"", try narrowed(marks: ["figcaption": ""])),
        ("detailsSummary marks \"\"", try narrowed(marks: ["detailsSummary": ""])),
        ("only bold and italic", try narrowed(droppingMarks: ["strike", "highlight", "underline", "subscript",
            "superscript", "textColor", "backgroundColor", "code", "link"])),
        // Nodes a host simply doesn't have.
        ("no tables", try narrowed(droppingNodes: ["table", "tableRow", "tableCell", "tableHeader"])),
        ("no figures", try narrowed(droppingNodes: ["figure", "figcaption"])),
        ("no details", try narrowed(droppingNodes: ["details", "detailsSummary", "detailsContent"])),
        ("no task lists", try narrowed(droppingNodes: ["taskList", "taskItem"])),
        ("no headings or code blocks", try narrowed(droppingNodes: ["heading", "codeBlock"])),
        ("no lists", try narrowed(droppingNodes: ["bulletList", "orderedList", "listItem", "taskList", "taskItem"])),
    ]
}

// MARK: - The corpus

/// Markup in the shapes other editors write it. Each source is what that app
/// actually emits in outline — the attributes are trimmed, the structure isn't.
let foreignHTMLCorpus: [(String, String)] = [
    ("Google Docs: wrapper <b>, styled spans, paragraphs", """
    <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1a2b"><p dir="ltr" \
    style="line-height:1.38;margin-top:0pt;margin-bottom:0pt;"><span style="font-size:11pt;font-family:Arial;\
    font-weight:700;">Quarterly</span><span style="font-size:11pt;font-weight:400;"> planning notes</span></p>\
    <br><p dir="ltr"><span style="font-style:italic;">Second</span><span> paragraph here.</span></p></b>
    """),
    ("Google Docs: lists with a sub-list directly in the list", """
    <b style="font-weight:normal;" id="docs-internal-guid-3c4d"><ul style="margin-top:0;"><li dir="ltr" \
    style="list-style-type:disc;" aria-level="1"><p dir="ltr" role="presentation"><span>Apples</span></p></li>\
    <ul style="margin-top:0;"><li dir="ltr" aria-level="2"><p dir="ltr" role="presentation"><span>Granny \
    Smith</span></p></li></ul><li dir="ltr" aria-level="1"><p dir="ltr" role="presentation"><span>Pears</span>\
    </p></li></ul></b>
    """),
    ("Google Docs: table with colgroup and bold header cells", """
    <b style="font-weight:normal;" id="docs-internal-guid-5e6f"><div dir="ltr" style="margin-left:0pt;" \
    align="left"><table style="border:none;border-collapse:collapse;"><colgroup><col width="120"><col \
    width="240"></colgroup><tbody><tr style="height:0pt"><td style="border-left:solid #000 1pt;"><p dir="ltr">\
    <span style="font-weight:700;">Name</span></p></td><td><p dir="ltr"><span style="font-weight:700;">Role\
    </span></p></td></tr><tr><td><p dir="ltr"><span>Ada</span></p></td><td><p dir="ltr"><span>Engineer</span>\
    </p></td></tr></tbody></table></div></b>
    """),
    ("Google Sheets: styled cells", """
    <google-sheets-html-origin><style type="text/css"><!--td {border: 1px solid #cccccc;}br {mso-data-placement:\
    same-cell;}--></style><table xmlns="http://www.w3.org/1999/xhtml" cellspacing="0" cellpadding="0" dir="ltr" \
    border="1" data-sheets-root="1"><colgroup><col width="100"/><col width="80"/></colgroup><tbody><tr \
    style="height:21px;"><td style="font-weight:bold;overflow:hidden;">Region</td><td style="font-weight:bold;">\
    Total</td></tr><tr><td>North</td><td style="text-align:right;">1,204</td></tr></tbody></table>
    """),
    ("Notion: headings, toggle, quote holding a list, figure", """
    <h1>Project brief</h1><p>Owner: <strong>Grace</strong> · <em>draft</em></p><details><summary>Open \
    questions</summary><p>Which launch week?</p><ul><li>Budget sign-off</li></ul></details><blockquote><p>Quote \
    lead</p><ul><li>quoted item one</li><li>quoted item two</li></ul></blockquote><figure><img \
    src="https://www.notion.so/image/x.png" alt="diagram"><figcaption>System diagram</figcaption></figure>\
    <p>Closing line.</p>
    """),
    ("Word: MsoNormal paragraphs, conditional comments, fake list bullets", """
    <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><meta name=Generator content="Microsoft Word 15">\
    <style><!-- p.MsoNormal {margin:0cm; font-size:11.0pt;} --></style><!--[if gte mso 9]><xml><w:WordDocument>\
    </w:WordDocument></xml><![endif]--></head><body lang=EN-US><div class=WordSection1><p class=MsoNormal><b>\
    <span lang=EN-US>Meeting minutes</span></b><o:p></o:p></p><p class=MsoListParagraphCxSpFirst \
    style='text-indent:-18.0pt;mso-list:l0 level1 lfo1'><![if !supportLists]><span style='font-family:Symbol'>\
    <span style='mso-list:Ignore'>·<span style='font:7.0pt "Times New Roman"'>&nbsp;&nbsp; </span></span></span>\
    <![endif]><span lang=EN-US>Action item alpha</span><o:p></o:p></p><p class=MsoNormal><i>Signed</i>, the \
    committee<o:p></o:p></p></div></body></html>
    """),
    ("Word: table with widths and header row", """
    <table class=MsoTableGrid border=1 cellspacing=0 cellpadding=0 style='border-collapse:collapse'><tr><td \
    width=200 valign=top style='width:150.0pt'><p class=MsoNormal><b>Item<o:p></o:p></b></p></td><td width=100 \
    valign=top><p class=MsoNormal><b>Qty</b></p></td></tr><tr><td width=200 valign=top><p class=MsoNormal>\
    Widgets</p></td><td width=100><p class=MsoNormal>12</p></td></tr></table>
    """),
    ("Apple Notes: full document, divs, checklist", """
    <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN"><html><head><meta http-equiv="Content-Type" \
    content="text/html; charset=UTF-8"><style type="text/css">p.p1 {margin: 0.0px} span.s1 {font-weight: bold}\
    </style><title>Groceries</title></head><body><h1>Groceries</h1><div>Things to buy</div><div><br></div>\
    <ul class="Apple-dash-list"><li>milk</li><li>eggs</li></ul><ul><li><input type="checkbox" checked>bread\
    </li><li><input type="checkbox">butter</li></ul><div><span class="s1">Remember</span> the receipt</div>\
    </body></html>
    """),
    ("Cocoa HTML Writer: classes carry the emphasis", """
    <!DOCTYPE html><html><head><style type="text/css">p.p1 {margin: 0.0px 0.0px 0.0px 0.0px} span.s1 \
    {font-weight: bold} span.s2 {font-style: italic}</style></head><body><p class="p1"><span class="s1">Bold \
    lead</span> then <span class="s2">slanted</span> words</p><p class="p1">second line<br>after a break</p>\
    </body></html>
    """),
    ("GitHub markdown: heading anchors, task list, highlighted code, table", """
    <div class="markdown-heading" dir="auto"><h2 tabindex="-1" class="heading-element" dir="auto">Install\
    </h2><a id="user-content-install" class="anchor" aria-label="Permalink: Install" href="#install"><svg \
    class="octicon" viewBox="0 0 16 16" aria-hidden="true"><path d="m7.775 3.275"></path></svg></a></div>\
    <ul class="contains-task-list"><li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" \
    disabled checked> clone the repo</li><li class="task-list-item"><input type="checkbox" \
    class="task-list-item-checkbox" disabled> run the build</li></ul><div class="highlight highlight-source-shell">\
    <pre><span class="pl-c1">swift</span> build --product demo\nswift run</pre></div><markdown-accessiblity-table>\
    <table><thead><tr><th align="left">Flag</th><th align="right">Default</th></tr></thead><tbody><tr><td \
    align="left"><code>--fast</code></td><td align="right">off</td></tr></tbody></table></markdown-accessiblity-table>
    """),
    ("Figure with a caption and content after it", """
    <figure><img src="https://example.test/a.png" alt="a"><p>inside figure</p><figcaption>The caption</figcaption>\
    <p>after the caption</p><ul><li>and a list</li></ul></figure><p>outside</p>
    """),
    ("Lists directly inside lists, ordered and unordered", """
    <ol start="3"><li>three</li><ol><li>three point one</li><ul><li>deep bullet</li></ul></ol><li>four</li></ol>\
    <ul><ul><li>orphan sub-item</li></ul><li>first real item</li></ul>
    """),
    ("Task list with a sub-list and nested checkboxes", """
    <ul data-type="taskList"><li data-type="taskItem" data-checked="true"><label><input type="checkbox" \
    checked></label><div><p>parent task</p></div></li><ul><li>loose sub bullet</li></ul><li data-type="taskItem" \
    data-checked="false"><p>second task</p><ul data-type="taskList"><li data-type="taskItem" data-checked="true">\
    <p>nested task</p></li></ul></li></ul>
    """),
    ("Table with th, thead, colspan and rowspan", """
    <table><caption>Schedule</caption><thead><tr><th colspan="2">Morning</th><th>Noon</th></tr></thead><tbody>\
    <tr><td rowspan="2">Mon</td><td>standup</td><td>lunch</td></tr><tr><td>review</td><td>walk</td></tr>\
    </tbody><tfoot><tr><td colspan="3">end of week</td></tr></tfoot></table>
    """),
    ("Details with block content and a nested details", """
    <details open><summary>Outer <b>toggle</b></summary><p>outer body</p><details><summary>Inner toggle\
    </summary><blockquote><p>inner quote</p></blockquote></details><pre><code>code in toggle</code></pre>\
    </details><details><p>no summary here</p></details>
    """),
    ("Blockquote holding lists, headings and code", """
    <blockquote><h3>Quoted heading</h3><ol><li><p>quoted step</p><pre><code class="language-swift">let x = 1\
    </code></pre></li></ol><blockquote><p>twice quoted</p></blockquote></blockquote>
    """),
    ("Pre and code with entities and markup inside", """
    <pre><code class="language-html">&lt;div class="x"&gt;
      a &amp;&amp; b
    &lt;/div&gt;</code></pre><p>Inline <code>x &lt; y</code> and <kbd>Cmd</kbd>-<kbd>K</kbd>.</p>
    """),
    ("Inline marks nested oddly and crossed", """
    <p><b>bold <i>both</b> italic</i> plain <u><s>under struck</s></u> <strong><code>bold code</code></strong> \
    <em>em <a href="https://example.test">linked <b>strong link</b></a> tail</em></p><p><b>unclosed bold \
    <i>and italic</p><p>next paragraph</p>
    """),
    ("Spans with styles, nbsp and br inside marks", """
    <p><span style="color:#ff0000;font-weight:600">red bold</span>&nbsp;<span style="background-color:yellow;\
    font-style:oblique">highlit</span><span style="text-decoration:underline line-through">both lines</span>\
    <span style="vertical-align:super">sup</span></p><p><b>line one<br>line two</b><i>after<br></i>end</p>
    """),
    ("Images inside links, and links around blocks", """
    <p><a href="https://example.test"><img src="https://example.test/logo.png" alt="logo"> Logo text</a></p>\
    <a href="https://example.test/card"><div><h4>Card title</h4><p>Card body</p></div></a>
    """),
    ("aria-hidden, script, style and template are not content", """
    <p>visible one<span aria-hidden="true">HIDDENSPAN</span> visible two</p><script>var HIDDENSCRIPT = 1;\
    </script><style>.HIDDENSTYLE { color: red }</style><template><p>HIDDENTEMPLATE</p></template><div \
    aria-hidden="true"><p>HIDDENDIV</p></div><p>visible three</p><noscript>HIDDENNOSCRIPT</noscript>
    """),
    ("KaTeX: MathML beside an aria-hidden rendering", """
    <p>Area is <span class="katex"><span class="katex-mathml"><math><semantics><mrow><mi>π</mi><msup><mi>r</mi>\
    <mn>2</mn></msup></mrow><annotation encoding="application/x-tex">\\pi r^2</annotation></semantics></math>\
    </span><span class="katex-html" aria-hidden="true"><span class="base">πr2</span></span></span> exactly.</p>
    """),
    ("Omitted end tags", """
    <p>first para<p>second para<ul><li>item a<li>item b</ul><table><tr><td>c1<td>c2<tr><td>c3<td>c4</table>\
    <dl><dt>term<dd>definition</dl>
    """),
    ("Stray inline content between blocks and in odd places", """
    loose text <b>bold loose</b><h2>Heading <em>emph</em></h2>between blocks<ul>stray in list<li>real item\
    </li></ul><table>stray in table<tr><td>cell</td></tr></table><hr>after rule
    """),
    ("Sections, articles and headers wrapping content", """
    <article><header><h1>Post title</h1><p class="byline">by <a href="/u">someone</a></p></header><section>\
    <h2>Part one</h2><p>Body of part one.</p><aside>An aside note</aside></section><footer><small>Footer \
    small print</small></footer></article>
    """),
    ("Headings holding blocks and images", """
    <h2><img src="https://example.test/icon.png" alt="i"> Iconed heading</h2><h3><p>paragraph in heading</p></h3>\
    <p><img src="https://example.test/inline.png"> text after image</p>
    """),
    ("A cell holding lists and a nested table", """
    <table><tr><th>Outer head</th></tr><tr><td><ul><li>cell list item</li></ul><table><tr><td>nested cell\
    </td></tr></table><p>cell tail</p></td></tr></table>
    """),
]

// MARK: - Visible words of the source

private let hiddenElements: Set<String> = ["script", "style", "template", "head", "title", "noscript", "math",
                                           "svg", "iframe", "object"]
private let voidElements: Set<String> = ["br", "hr", "img", "input", "col", "wbr", "meta", "link", "source", "area"]
private let wordBreakingElements: Set<String> = [
    "p", "div", "ul", "ol", "li", "table", "tr", "td", "th", "thead", "tbody", "tfoot", "caption", "h1", "h2",
    "h3", "h4", "h5", "h6", "blockquote", "pre", "figure", "figcaption", "details", "summary", "section",
    "article", "header", "footer", "aside", "dl", "dt", "dd", "br", "hr", "main", "nav",
]

private func decodeForTest(_ s: String) -> String {
    var out = s
    for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                            ("&nbsp;", "\u{00A0}"), ("&amp;", "&")] {
        out = out.replacingOccurrences(of: entity, with: value)
    }
    return out
}

private func words(_ s: String) -> [String] {
    s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

/// The words a browser would show for `html`, in order. Deliberately its own
/// small scanner rather than the parser's tokenizer — a property that shares
/// the code under test shares its bugs.
func visibleWords(ofHTML html: String) -> [String] {
    let chars = Array(html.unicodeScalars)
    var text = ""
    var hidden: [String] = []   // the stack of open hidden elements, by name
    var i = 0
    func readTag(_ from: Int) -> (end: Int, body: String) {
        var j = from + 1
        var quote: Unicode.Scalar?
        while j < chars.count {
            let c = chars[j]
            if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { break }
            j += 1
        }
        return (j, String(String.UnicodeScalarView(chars[(from + 1)..<min(j, chars.count)])))
    }
    while i < chars.count {
        let c = chars[i]
        let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
        if c == "<", let n = next, n == "!" || n == "?" {
            if String(String.UnicodeScalarView(chars[i..<min(i + 4, chars.count)])) == "<!--" {
                var j = i + 4
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = j + 3
            } else {
                var j = i
                while j < chars.count, chars[j] != ">" { j += 1 }
                i = j + 1
            }
            continue
        }
        if c == "<", let n = next, n == "/" || n.properties.isAlphabetic {
            let (end, body) = readTag(i)
            i = end + 1
            let closing = body.hasPrefix("/")
            let nameEnd = body.dropFirst(closing ? 1 : 0).prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
            let name = nameEnd.lowercased()
            if closing {
                if hidden.last == name { hidden.removeLast() }
            } else {
                let selfClosing = body.hasSuffix("/") || voidElements.contains(name)
                let ariaHidden = body.range(of: #"aria-hidden\s*=\s*["']?true"#, options: .regularExpression) != nil
                if !selfClosing, hiddenElements.contains(name) || ariaHidden || !hidden.isEmpty {
                    // Inside a hidden element, track nesting of every element so
                    // the right close tag ends it.
                    hidden.append(name)
                }
            }
            if hidden.isEmpty, wordBreakingElements.contains(name) { text += " " }
            continue
        }
        if hidden.isEmpty { text.unicodeScalars.append(c) }
        i += 1
    }
    return words(decodeForTest(text))
}

// MARK: - Words of the document

/// The document's words: text runs joined within a textblock, with every block
/// boundary, hard break and leaf atom a word break.
func documentWords(_ doc: Node) -> [String] {
    var text = ""
    func walk(_ n: Node) {
        if n.isText { text += n.text ?? ""; return }
        if n.isInline {
            text += " "
            if n.isLeaf, let leaf = n.type.spec.leafText { text += leaf(n) + " " }
            return
        }
        text += " "
        for i in 0 ..< n.childCount { walk(n.child(i)) }
        text += " "
    }
    walk(doc)
    return words(text)
}

/// The first word of `expected` that `actual` doesn't contain in order, with
/// its index — nil when every word is there.
func firstMissingWord(_ expected: [String], in actual: [String]) -> (Int, String)? {
    var j = 0
    for (k, w) in expected.enumerated() {
        while j < actual.count, actual[j] != w { j += 1 }
        if j == actual.count { return (k, w) }
        j += 1
    }
    return nil
}

private func sketch(_ n: Node) -> String {
    if n.isText { return (n.text ?? "").debugDescription }
    let kids = (0 ..< n.childCount).map { sketch(n.child($0)) }
    return kids.isEmpty ? n.type.name : n.type.name + "(" + kids.joined(separator: " ") + ")"
}

// MARK: - Known bugs

/// Pairs the property currently fails on because of bugs in the importer, not
/// in the property. Each is excluded from the one clause it breaks — and only
/// that clause — so the rest of the pair is still checked, and nothing here
/// asserts the wrong behaviour: once a bug is fixed its entry is dead weight,
/// not a failure. Delete the entry with the fix.
private enum KnownIssue {
    /// The parse throws `invalidDocument` rather than returning a document.
    case throwsInvalidDocument
    /// The document is valid, but visible words are lost or glued together.
    case losesWords
}

private let knownIssues: [(schema: String, source: String, issue: KnownIssue, bug: String)] = []

private func knownIssue(_ schemaLabel: String, _ source: String, _ issue: KnownIssue) -> Bool {
    knownIssues.contains { entry in
        (entry.schema == "*" || entry.schema == schemaLabel) && (entry.source == "*" || entry.source == source)
            && entry.issue == issue
    }
}

// MARK: - The property

func registerHTMLImportPropertyTests() {
    test("html import property: the scanner sees what a browser shows") {
        // The property is only as good as its notion of visible text, so pin it.
        try expectEqual(visibleWords(ofHTML: "<p>a<b>b</b> c</p><script>x</script><p aria-hidden=\"true\">y</p>d"),
                        ["ab", "c", "d"])
        // A declaration is skipped without breaking the word it sits in.
        try expectEqual(visibleWords(ofHTML: "<!-- note -->x&amp;y<br>z<![if !a]>w"), ["x&y", "zw"])
        try expectEqual(visibleWords(ofHTML: "<span aria-hidden=\"true\"><span>q</span>r</span>s"), ["s"])
        // And the document side: blocks and breaks separate words; marks don't.
        let d = try HTMLParser.parse("<p>a<b>b</b></p><p>c<br>d</p>", schema: schema)
        try expectEqual(documentWords(d), ["ab", "c", "d"])
        try expectEqual(firstMissingWord(["a", "c"], in: ["a", "b", "c"]).map { $0.1 }, nil)
        try expectEqual(firstMissingWord(["c", "a"], in: ["a", "b", "c"]).map { $0.1 }, "a")
    }

    test("html import property: foreign markup parses valid and keeps every visible word, in every narrowed schema") {
        let schemas = try importSchemas()
        var failures: [String] = []
        for (source, html) in foreignHTMLCorpus {
            let expected = visibleWords(ofHTML: html)
            try expect(!expected.isEmpty, "\(source): the source shows nothing — the case proves nothing")
            for word in expected where word.hasPrefix("HIDDEN") {
                failures.append("\(source): the scanner saw hidden text \(word)")
            }
            for (label, narrow) in schemas {
                let doc: Node
                do {
                    doc = try HTMLParser.parse(html, schema: narrow)
                } catch {
                    if case HTMLParseError.invalidDocument = error,
                       knownIssue(label, source, .throwsInvalidDocument) { continue }
                    failures.append("[\(label)] \(source): threw \(error)")
                    continue
                }
                do { try doc.check() } catch {
                    failures.append("[\(label)] \(source): invalid document — \(error)\n    \(sketch(doc))")
                    continue
                }
                let actual = documentWords(doc)
                if let (index, word) = firstMissingWord(expected, in: actual),
                   !knownIssue(label, source, .losesWords) {
                    failures.append("[\(label)] \(source): lost word #\(index) \(word.debugDescription)\n"
                                    + "    expected \(expected)\n    got      \(actual)\n    \(sketch(doc))")
                }
                if let leaked = actual.first(where: { $0.contains("HIDDEN") }) {
                    failures.append("[\(label)] \(source): hidden text \(leaked) became content")
                }
            }
        }
        try expect(failures.isEmpty, "\(failures.count) failure(s):\n" + failures.joined(separator: "\n"))
    }
}
