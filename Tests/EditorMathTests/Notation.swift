import Foundation
import EditorMath
import TestHarness

// The other axis. `mathCorpus` is chosen by subject — the notation a document
// about calculus or probability reaches for — and it is a good test of whether
// real formulas come out right. What it is not is a test of the parser's
// vocabulary: a hundred formulas about mathematics use the same few dozen
// commands over and over, and every command outside that habit is unexercised
// even though the parser claims to know it.
//
// So this corpus is chosen by construct instead. One entry per family, each
// listing the family's members: every Greek letter, every matrix environment,
// every accent, every size of delimiter. A command that was added and then
// broken shows up here and nowhere else.
//
// Deliberately not here: `\hline`, which the parser rejects as unknown. It's a
// real construct — a rule between rows of an `array` — and this corpus is for
// what works. Writing it down as a gap rather than as a failing test.
let notationCorpus: [(group: String, latex: String)] = [
    // MARK: Greek
    //
    // Split across entries so a single missing letter names itself in the
    // failure rather than hiding in one enormous string.
    ("greek", #"\alpha\beta\gamma\delta\epsilon\zeta\eta\theta"#),
    ("greek", #"\iota\kappa\lambda\mu\nu\xi\omicron\pi"#),
    ("greek", #"\rho\sigma\tau\upsilon\phi\chi\psi\omega"#),
    ("greek", #"\varepsilon\vartheta\varpi\varrho\varsigma\varphi"#),
    ("greek", #"\Gamma\Delta\Theta\Lambda\Xi\Pi\Sigma"#),
    ("greek", #"\Upsilon\Phi\Psi\Omega"#),

    // MARK: Matrix environments
    //
    // Each spelling brings its own delimiters, and they are easy to get
    // crossed — a `vmatrix` drawn with parentheses is a determinant that
    // reads as a matrix.
    ("matrix", #"\begin{matrix}a&b\\c&d\end{matrix}"#),
    ("matrix", #"\begin{pmatrix}a&b\\c&d\end{pmatrix}"#),
    ("matrix", #"\begin{bmatrix}1&0\\0&1\end{bmatrix}"#),
    ("matrix", #"\begin{vmatrix}a&b\\c&d\end{vmatrix}"#),
    ("matrix", #"\begin{Vmatrix}x\\y\end{Vmatrix}"#),
    ("matrix", #"\begin{Bmatrix}a&b\end{Bmatrix}"#),
    ("matrix", #"\begin{smallmatrix}a&b\\c&d\end{smallmatrix}"#),
    ("matrix", #"\begin{cases}x&x\ge 0\\-x&x<0\end{cases}"#),
    ("matrix", #"\begin{array}{cc}a&b\\c&d\end{array}"#),
    ("matrix", #"\begin{aligned}a&=b\\c&=d\end{aligned}"#),
    ("matrix", #"\begin{pmatrix}\begin{pmatrix}a\end{pmatrix}&b\\c&d\end{pmatrix}"#),

    // MARK: Accents
    ("accent", #"\hat{a}\bar{b}\vec{c}\tilde{d}\dot{e}\ddot{f}"#),
    ("accent", #"\acute{a}\grave{b}\breve{c}\check{d}\mathring{e}"#),
    ("accent", #"\widehat{abc}\widetilde{xyz}"#),
    ("accent", #"\overline{AB}\underline{CD}"#),
    ("accent", #"\overbrace{a+b}^{n}"#),
    ("accent", #"\hat{\hat{x}}"#),          // an accent over an accented box
    ("accent", #"f'(x)+g''(x)"#),           // primes, which are accents by another name

    // MARK: Delimiters and their sizes
    //
    // `\left…\right` grows to fit; the `\big` family is fixed at four sizes.
    // Both exist because neither alone is enough, so both need exercising.
    ("delimiter", #"\big(x\big)\Big[y\Big]\bigg\{z\bigg\}\Bigg|w\Bigg|"#),
    ("delimiter", #"\bigl(a\bigr)\Bigl[b\Bigr]\biggl\{c\biggr\}\Biggl|d\Biggr|"#),
    ("delimiter", #"\lVert x\rVert+\lvert y\rvert"#),
    ("delimiter", #"\lbrace a\rbrace\lbrack b\rbrack"#),
    ("delimiter", #"\Vert v\Vert\vert w\vert"#),
    ("delimiter", #"\left\langle u,v\right\rangle"#),
    ("delimiter", #"\left.\frac{a}{b}\right|_{x=0}"#),   // the invisible delimiter

    // MARK: Fonts and styles
    ("style", #"\mathrm{d}x\,\mathit{y}\,\mathtt{code}"#),
    ("style", #"\mathfrak{g}\,\mathscr{L}\,\mathnormal{x}"#),
    ("style", #"\textbf{bold}\textit{italic}\texttt{mono}"#),
    ("style", #"\textrm{roman}\textsf{sans}\textnormal{plain}"#),
    ("style", #"\boldsymbol{\alpha}+\bm{v}"#),
    ("style", #"\displaystyle\frac{a}{b}+\textstyle\frac{a}{b}"#),
    ("style", #"\scriptstyle x+\scriptscriptstyle y"#),
    ("style", #"\tfrac{1}{2}+\dfrac{3}{4}"#),
    ("style", #"\dbinom{n}{k}+\tbinom{n}{k}"#),

    // MARK: Spacing
    //
    // Every one of these measures to a width and nothing else, so they are
    // written around a letter: a spacing command that silently does nothing
    // still "works" on its own.
    ("spacing", #"a\quad b\qquad c"#),
    ("spacing", #"a\,b\;c\!d"#),
    ("spacing", #"a\thinspace b\medspace c\thickspace d\enspace e"#),
    ("spacing", #"a\negthinspace b"#),
    ("spacing", #"a\nobreakspace b\space c"#),

    // MARK: Arrows
    ("arrow", #"\leftarrow\rightarrow\uparrow\downarrow\leftrightarrow\updownarrow"#),
    ("arrow", #"\Leftarrow\Rightarrow\Uparrow\Downarrow\Leftrightarrow\Updownarrow"#),
    ("arrow", #"\longleftarrow\longrightarrow\longleftrightarrow\longmapsto"#),
    ("arrow", #"\Longleftarrow\Longrightarrow\Longleftrightarrow"#),
    ("arrow", #"\hookleftarrow\hookrightarrow\nearrow\searrow\swarrow\nwarrow"#),
    ("arrow", #"\leftharpoonup\leftharpoondown\rightharpoonup\rightharpoondown"#),
    ("arrow", #"\rightleftharpoons\leadsto\gets\to"#),
    ("arrow", #"\nleftarrow\nrightarrow"#),
    ("arrow", #"x\implies y\impliedby z"#),

    // MARK: Relations
    ("relation", #"a\leq b\geq c\ne d\neq e"#),
    ("relation", #"a\leqslant b\geqslant c\ll d\gg e"#),
    ("relation", #"a\prec b\succ c\preceq d\succeq e"#),
    ("relation", #"a\approx b\approxeq c\cong d\simeq e"#),
    ("relation", #"a\asymp b\doteq c\propto d\bowtie e"#),
    ("relation", #"A\supset B\supseteq C\subsetneq D\supsetneq E"#),
    ("relation", #"A\nsubseteq B\nsupseteq C\sqsubseteq D\sqsupseteq E"#),
    ("relation", #"a\parallel b\dashv c\ni d\owns e\notin F"#),
    ("relation", #"\therefore\;\because\;\nmid\;\nexists"#),

    // MARK: Big operators
    //
    // These change size with style and take limits above and below, which is
    // more layout than an ordinary symbol and more to get wrong.
    ("bigop", #"\bigcup_{i}A_i\;\bigcap_{i}B_i\;\bigsqcup_{i}C_i"#),
    ("bigop", #"\bigvee_{i}p_i\;\bigwedge_{i}q_i\;\biguplus_{i}S_i"#),
    ("bigop", #"\bigodot_{i}x_i\;\bigoplus_{i}V_i\;\bigotimes_{i}W_i"#),
    ("bigop", #"\coprod_{i=1}^{n}X_i"#),
    ("bigop", #"\sum\limits_{i=1}^{n}i"#),
    ("bigop", #"\sum\nolimits_{i=1}^{n}i"#),

    // MARK: Binary operators
    ("binop", #"a\div b\ast c\star d\bullet e"#),
    ("binop", #"a\circ b\diamond c\odot d\ominus e\oslash f"#),
    ("binop", #"a\boxplus b\boxminus c\boxtimes d\boxdot e"#),
    ("binop", #"a\ltimes b\rtimes c\wr d\amalg e"#),
    ("binop", #"a\uplus b\sqcup c\sqcap d\wedge e\vee f"#),
    ("binop", #"\lnot p"#),

    // MARK: Standalone symbols
    ("symbol", #"\triangle\triangleleft\triangleright\bigtriangleup\bigtriangledown"#),
    ("symbol", #"\square\blacksquare\bigcirc\angle\measuredangle"#),
    ("symbol", #"\clubsuit\diamondsuit\heartsuit\spadesuit"#),
    ("symbol", #"\flat\sharp\natural"#),
    ("symbol", #"\dagger\ddagger\dag\ddag\maltese\checkmark"#),
    ("symbol", #"\pounds\circledR\degree"#),
    ("symbol", #"\aleph\beth\hbar\hslash\ell\imath\jmath\wp\mho"#),
    ("symbol", #"\surd\top\bot\Re\Im\backslash\emptyset"#),
    ("symbol", #"\prime\dprime"#),
    ("symbol", #"a\ldots b\dots c"#),
    ("symbol", #"\frown\smile"#),

    // MARK: Named functions
    //
    // Upright where a variable would be italic, which is the whole point of
    // having them: `sin` set as three letters reads as a product.
    ("function", #"\sin x+\cos y+\tan z"#),
    ("function", #"\cot x+\sec y+\csc z"#),
    ("function", #"\sinh x+\cosh y+\tanh z+\coth w"#),
    ("function", #"\arcsin x+\arccos y+\arctan z"#),
    ("function", #"\log x+\ln y+\lg z+\exp w"#),
    ("function", #"\deg f+\dim V+\ker T+\hom(A,B)"#),
    ("function", #"\arg z+\Pr(A)"#),
    ("function", #"\min A+\max B+\inf C+\sup D"#),
    ("function", #"\liminf_{n}a_n+\limsup_{n}b_n"#),
    ("function", #"\injlim A_i+\projlim B_i"#),
    ("function", #"\operatorname{sgn}(x)"#),
    ("function", #"x\bmod y+\pmod{n}+\mod{n}+\pod{n}"#),
    ("function", #"a\coloneqq b\colon c"#),
]

func registerNotationTests() {
    corpusChecks("notation", notationCorpus)

    test("notation: this corpus reaches well past the subject one") {
        // A guard on the corpus rather than on the code. The reason to keep
        // two corpora is that this one covers vocabulary the other never
        // reaches; if that stops being true it is duplicated effort, and the
        // number below says by how much.
        //
        // Per-entry would be the stricter check and isn't worth it: an entry
        // can cover an environment name or a construct with no `\command` in
        // it at all — `\begin{vmatrix}`, a nested accent, a prime — and would
        // read as redundant when it is the opposite.
        let already = Set(commands(in: mathCorpus.map(\.latex).joined()))
        let new = Set(commands(in: notationCorpus.map(\.latex).joined())).subtracting(already)
        try expect(new.count > 150,
                   "only \(new.count) commands here are new to the subject corpus")
    }
}

/// The `\command` names in a string.
private func commands(in latex: String) -> [String] {
    var found: [String] = []
    var rest = Substring(latex)
    while let slash = rest.firstIndex(of: "\\") {
        let after = rest.index(after: slash)
        let name = rest[after...].prefix(while: \.isLetter)
        if !name.isEmpty { found.append(String(name)) }
        rest = rest[(name.isEmpty ? (after == rest.endIndex ? after : rest.index(after: after)) : name.endIndex)...]
    }
    return found
}
