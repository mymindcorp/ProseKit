import Foundation
import EditorMath
import TestHarness

// A cross-section of the notation a real document reaches for: algebra through
// calculus, set theory and logic, linear algebra, probability, and functions.
// Every entry must parse and produce a drawable box — this is the suite that
// catches a missing command or a construct the layout has no case for.
//
// Written with raw string literals so the LaTeX reads exactly as it would in a
// document, without doubled backslashes.
let mathCorpus: [(group: String, latex: String)] = [
    // MARK: Algebra
    ("algebra", #"x + y = z"#),
    ("algebra", #"a - b = c"#),
    ("algebra", #"a \cdot b = ab"#),
    ("algebra", #"\frac{a}{b}"#),
    ("algebra", #"x^n + y^n"#),
    ("algebra", #"\sqrt{x}"#),
    ("algebra", #"\sqrt[n]{x}"#),
    ("algebra", #"\left|x-y\right|"#),
    ("algebra", #"\left\lfloor x \right\rfloor"#),
    ("algebra", #"\left\lceil x \right\rceil"#),
    ("algebra", #"\binom{n}{k}"#),
    ("algebra", #"ax^2 + bx + c = 0"#),
    ("algebra", #"x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}"#),
    ("algebra", #"x^2-y^2 = (x-y)(x+y)"#),
    ("algebra", #"p(x) = a_nx^n + a_{n-1}x^{n-1} + \cdots + a_0"#),
    ("algebra", #"z = a + bi"#),
    ("algebra", #"\overline{z} = a-bi"#),
    ("algebra", #"|z| = \sqrt{a^2+b^2}"#),
    ("algebra", #"z = re^{i\theta}"#),
    ("algebra", #"e^{i\pi}+1=0"#),

    // MARK: Series and calculus
    ("calculus", #"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}"#),
    ("calculus", #"\sum_{k=0}^{n} ar^k = a\frac{1-r^{n+1}}{1-r}"#),
    ("calculus", #"\prod_{k=1}^{n} k = n!"#),
    ("calculus", #"\lim_{x\to 0}\frac{\sin x}{x}=1"#),
    ("calculus", #"\lim_{x\to a^+}f(x)"#),
    ("calculus", #"\frac{d}{dx}f(x)"#),
    ("calculus", #"\frac{\partial f}{\partial x}"#),
    ("calculus", #"\frac{d^2y}{dx^2}"#),
    ("calculus", #"\int f(x)\,dx"#),
    ("calculus", #"\int_a^b f(x)\,dx"#),
    ("calculus", #"\iint_D f(x,y)\,dA"#),
    ("calculus", #"\iiint_V f(x,y,z)\,dV"#),
    ("calculus", #"\oint_C \mathbf{F}\cdot d\mathbf{r}"#),
    ("calculus", #"\nabla f"#),
    ("calculus", #"\nabla\cdot\mathbf{F}"#),
    ("calculus", #"\nabla\times\mathbf{F}"#),
    ("calculus", #"\nabla^2 f"#),
    ("calculus", #"\int_a^b f'(x)\,dx = \left.f(x)\right|_a^b"#),
    ("calculus", #"f(x)=\sum_{n=0}^{\infty}\frac{f^{(n)}(a)}{n!}(x-a)^n"#),
    ("calculus", #"\hat{f}(\xi)=\int_{-\infty}^{\infty}f(x)e^{-2\pi i x\xi}\,dx"#),

    // MARK: Sets and logic
    ("sets", #"x \in A"#),
    ("sets", #"A \subseteq B"#),
    ("sets", #"A \cup B \quad\text{and}\quad A \cap B"#),
    ("sets", #"A \setminus B"#),
    ("sets", #"\varnothing \subseteq A"#),
    ("sets", #"\{x\in\mathbb{R}\mid x>0\}"#),
    ("sets", #"|A|=n"#),
    ("sets", #"\mathcal{P}(A)"#),
    ("sets", #"\mathbb{N}\subset\mathbb{Z}\subset\mathbb{Q}\subset\mathbb{R}\subset\mathbb{C}"#),
    ("sets", #"[a,b)=\{x\in\mathbb{R}\mid a\le x<b\}"#),
    ("logic", #"\forall x\in A,\;P(x)\Rightarrow Q(x)"#),
    ("logic", #"\exists x\in A\text{ such that }P(x)"#),
    ("logic", #"\neg(P\land Q)"#),
    ("logic", #"P\land Q"#),
    ("logic", #"P\iff Q"#),
    ("logic", #"P\oplus Q"#),
    ("logic", #"\neg(P\lor Q)\iff(\neg P\land\neg Q)"#),
    ("logic", #"\exists!x\in A:\;P(x)"#),
    ("logic", #"\Gamma\models\varphi"#),
    ("logic", #"\Gamma\vdash\varphi"#),

    // MARK: Linear algebra
    ("linear", #"\mathbf{v}=\begin{pmatrix}v_1\\v_2\\v_3\end{pmatrix}"#),
    ("linear", #"\mathbf{a}\cdot\mathbf{b}=\sum_{i=1}^{n}a_ib_i"#),
    ("linear", #"\mathbf{a}\times\mathbf{b}"#),
    ("linear", #"\|\mathbf{x}\|_2=\sqrt{\sum_{i=1}^{n}x_i^2}"#),
    ("linear", #"A=\begin{pmatrix}a&b\\c&d\end{pmatrix}"#),
    ("linear", #"\det(A)=\begin{vmatrix}a&b\\c&d\end{vmatrix}=ad-bc"#),
    ("linear", #"I_n=\begin{pmatrix}1&0&\cdots&0\\0&1&\cdots&0\\\vdots&\vdots&\ddots&\vdots\\0&0&\cdots&1\end{pmatrix}"#),
    ("linear", #"A^{\mathsf{T}}"#),
    ("linear", #"A^{-1}=\frac{1}{ad-bc}\begin{pmatrix}d&-b\\-c&a\end{pmatrix}"#),
    ("linear", #"(AB)_{ij}=\sum_{k=1}^{n}A_{ik}B_{kj}"#),
    ("linear", #"\begin{cases}2x+y=5\\x-y=1\end{cases}"#),
    ("linear", #"A\mathbf{v}=\lambda\mathbf{v}"#),
    ("linear", #"\det(A-\lambda I)=0"#),
    ("linear", #"\operatorname{rank}(A)+\operatorname{nullity}(A)=n"#),
    ("linear", #"\langle\mathbf{u},\mathbf{v}\rangle=\mathbf{u}^{\mathsf{T}}\mathbf{v}"#),
    ("linear", #"\mathbf{u}\perp\mathbf{v}\iff\mathbf{u}\cdot\mathbf{v}=0"#),
    ("linear", #"V\otimes W"#),
    ("linear", #"V\oplus W"#),
    ("linear", #"\mathbf{x}^{\mathsf{T}}=\begin{pmatrix}x_1&x_2&\cdots&x_n\end{pmatrix}"#),
    ("linear", #"\left[\begin{array}{cc|c}1&2&3\\4&5&6\end{array}\right]"#),

    // MARK: Probability and statistics
    ("probability", #"P(A)=\frac{|A|}{|\Omega|}"#),
    ("probability", #"P(A\mid B)=\frac{P(A\cap B)}{P(B)}"#),
    ("probability", #"P(A\mid B)=\frac{P(B\mid A)P(A)}{P(B)}"#),
    ("probability", #"\mathbb{E}[X]=\sum_x xP(X=x)"#),
    ("probability", #"\operatorname{Var}(X)=\mathbb{E}\left[(X-\mu)^2\right]"#),
    ("probability", #"\sigma_X=\sqrt{\operatorname{Var}(X)}"#),
    ("probability", #"P(X=k)=\binom{n}{k}p^k(1-p)^{n-k}"#),
    ("probability", #"X\sim\mathcal{N}(\mu,\sigma^2)"#),
    ("probability", #"\operatorname{Cov}(X,Y)=\mathbb{E}[(X-\mu_X)(Y-\mu_Y)]"#),
    ("probability", #"\rho_{X,Y}=\frac{\operatorname{Cov}(X,Y)}{\sigma_X\sigma_Y}"#),

    // MARK: Functions, sequences, number theory
    ("functions", #"f:A\to B,\quad x\mapsto f(x)"#),
    ("functions", #"f(x)=\begin{cases}x^2,&x\ge 0\\-x,&x<0\end{cases}"#),
    ("functions", #"(f\circ g)(x)=f(g(x))"#),
    ("functions", #"f^{-1}(f(x))=x"#),
    ("functions", #"\lim_{n\to\infty}a_n=L"#),
    ("functions", #"a_n=a_{n-1}+a_{n-2}"#),
    ("functions", #"\gcd(a,b)=\gcd(b,a\bmod b)"#),
    ("functions", #"a\equiv b\pmod n"#),
    ("functions", #"x=a_0+\cfrac{1}{a_1+\cfrac{1}{a_2+\cfrac{1}{\ddots}}}"#),
    ("functions", #"\underbrace{a+\cdots+a}_{n\text{ terms}}=na"#),
]

func registerCorpusTests() {
    corpusChecks("corpus", mathCorpus)
}

/// The three things every corpus entry has to do, whichever axis it was
/// chosen along: parse, measure to something drawable, and survive the switch
/// to inline style.
func corpusChecks(_ name: String, _ corpus: [(group: String, latex: String)]) {
    test("\(name): every formula parses") {
        var failures: [String] = []
        for entry in corpus {
            if let error = typesetter().layout(entry.latex, display: true).error {
                failures.append("  \(entry.latex)\n      → \(error)")
            }
        }
        try expect(failures.isEmpty, "\(failures.count)/\(corpus.count) failed to parse:\n"
                   + failures.joined(separator: "\n"))
    }

    test("\(name): every formula produces a drawable box") {
        var failures: [String] = []
        for entry in corpus {
            let box = typesetter().layout(entry.latex, display: true).box
            // Finite, positive, and actually inked — a formula that silently
            // measured to nothing would still "render" without this.
            let ok = box.width.isFinite && box.ascent.isFinite && box.descent.isFinite
                && box.width > 0 && box.height > 0
            if !ok {
                failures.append("  \(entry.latex) → w=\(box.width) a=\(box.ascent) d=\(box.descent)")
            }
        }
        try expect(failures.isEmpty, "\(failures.count) produced no drawable box:\n"
                   + failures.joined(separator: "\n"))
    }

    test("\(name): every formula renders the same inline as in display style") {
        // Inline style changes sizes and limit placement but must never fail.
        var failures: [String] = []
        for entry in corpus {
            let result = typesetter().layout(entry.latex, display: false)
            if result.isError || result.box.width <= 0 {
                failures.append("  \(entry.latex) → \(result.error ?? "empty box")")
            }
        }
        try expect(failures.isEmpty, "\(failures.count) failed inline:\n" + failures.joined(separator: "\n"))
    }
}
