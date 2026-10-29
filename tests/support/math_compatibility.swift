/// Synthetic notation shared by the document and native attachment checks.
enum MathCompatibility {
    struct Sample {
        let name: String
        let latex: String
        var canonical: String? = nil
    }

    static let samples: [Sample] = [
        .init(name: "imaginary_unit", latex: #"e^{\ii\pi/4}"#, canonical: #"e^{\mathrm{i}\pi/4}"#),
        .init(name: "euler_constant", latex: #"\ee^{-x}"#, canonical: #"\mathrm{e}^{-x}"#),
        .init(name: "bold_math", latex: #"\bm{\alpha+x}"#, canonical: #"\boldsymbol{\alpha+x}"#),
        .init(name: "argmin", latex: #"\argmin_{x\in X}f(x)"#, canonical: #"\operatorname*{arg\,min}_{x\in X}f(x)"#),
        .init(name: "argmax", latex: #"\argmax_{x\in X}f(x)"#, canonical: #"\operatorname*{arg\,max}_{x\in X}f(x)"#),
        .init(name: "sign_operator", latex: #"\sgn(x)"#, canonical: #"\operatorname{sgn}(x)"#),
        .init(name: "diagonal_operator", latex: #"\diag(1,2)"#, canonical: #"\operatorname{diag}(1,2)"#),
        .init(name: "quantum_phase", latex: #"F_2\ket\chi=\frac1{\sqrt2}(e^{\ii\pi/4}\ket0+e^{-\ii\pi/4}\ket1)"#),
        .init(name: "quantum_tensor", latex: #"\ket-\otimes\frac{\ket0-\ii\ket1}{\sqrt2}\otimes\frac{\ket0+e^{3\pi\ii/4}\ket1}{\sqrt2}"#),
        .init(name: "braket", latex: #"\braket{\psi|\phi}"#),
        .init(name: "declared_operator", latex: #"\DeclareMathOperator{\Var}{Var}\Var(X)"#),
        .init(name: "paired_delimiter", latex: #"\DeclarePairedDelimiter{\ceil}{\lceil}{\rceil}\ceil{x}"#),
        .init(name: "definition_relation", latex: #"a\coloneq b"#),
        .init(name: "extended_arrow", latex: #"A\xRightarrow{f}B"#),
        .init(name: "brackets", latex: #"\overbracket{a+b}+\underbracket{c+d}"#),
        .init(name: "split_fraction", latex: #"\splitfrac{a+b}{c+d}"#),
        .init(name: "cramped", latex: #"\cramped{x^2}"#),
        .init(name: "aligned_box", latex: #"\begin{aligned}\Aboxed{a&=b}\end{aligned}"#),
        .init(name: "centered_vertical_dots", latex: #"\vdotswithin{=}"#),
        .init(name: "display_cases", latex: #"\begin{dcases}x^2&x>0\\0&x\le0\end{dcases}"#),
        .init(name: "right_cases", latex: #"\begin{rcases}a\\b\end{rcases}=c"#),
        .init(name: "aligned_matrix", latex: #"\begin{pmatrix*}[r]1&-2\\3&4\end{pmatrix*}"#),
        .init(name: "multlined", latex: #"\begin{multlined}a+b\\+c+d\end{multlined}"#),
        .init(name: "differential", latex: #"\int f(x)\dd{x}"#),
        .init(name: "higher_differential", latex: #"\dd[2]{x}"#),
        .init(name: "evaluated", latex: #"\eval{x^2}_0^1"#),
        .init(name: "parenthesis_quantity", latex: #"\pqty{\frac{a}{b}}"#),
        .init(name: "bracket_quantity", latex: #"\bqty{x}+\Bqty{y}+\vqty{z}"#),
        .init(name: "matrix_quantity", latex: #"\mqty(a&b\\c&d)"#),
        .init(name: "commutator", latex: #"\comm{A}{B}+\acomm{A}{B}"#),
        .init(name: "unit_vector", latex: #"\vu{x}"#),
        .init(name: "cross_product", latex: #"\cross{a}{b}"#),
        .init(name: "trace", latex: #"\Tr A+\tr B"#),
        .init(name: "rank", latex: #"\rank A"#),
        .init(name: "inner_product", latex: #"\innerproduct{\psi}{\phi}"#),
        .init(name: "outer_product", latex: #"\outerproduct{\psi}{\phi}"#),
        .init(name: "matrix_element", latex: #"\matrixelement{\psi}{A}{\phi}"#),
        .init(name: "ordinary_division", latex: #"a\div b"#),
        .init(name: "blackboard_indicator", latex: #"\mathbbm{1}_A"#),
        .init(name: "double_stroke_indicator", latex: #"\mathds{1}_A"#),
        .init(name: "nice_fraction", latex: #"\nicefrac{1}{2}"#),
        .init(name: "units", latex: #"\units[3]{m}"#),
        .init(name: "unit_fraction", latex: #"\unitfrac[3]{m}{s}"#),
        .init(name: "upright_greek", latex: #"\upmu+\uppi+\Upomega"#),
        .init(name: "unit_symbols", latex: #"30\degree+20\celsius+3\ohm"#),
        .init(name: "centered_negation", latex: #"P\centernot\implies Q"#),
    ]
}
