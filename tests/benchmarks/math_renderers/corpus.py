"""Synthetic, public TeX fixtures; no conversations or application data are read."""
import json
from pathlib import Path


def fixtures():
    rows = []

    def add(group, name, tex, mode="display", valid=True):
        rows.append(dict(id=name, group=group, latex=tex, mode=mode, valid=valid))

    core = {
        "polynomial": r"x_i^2+2x_i+1=0",
        "quadratic": r"x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}",
        "nested_fraction": r"\frac{1}{1+\frac{1}{1+\frac{1}{x}}}",
        "binomial": r"\binom{n}{k}=\frac{n!}{k!(n-k)!}",
        "indexed_root": r"\sqrt[3]{x^2+1}",
        "nested_root": r"\sqrt{1+\sqrt{1+x^2}}",
        "root_subscript": r"\sqrt{f_c}",
        "sum": r"\sum_{i=1}^{n} i=\frac{n(n+1)}{2}",
        "product": r"\prod_{k=1}^{n}k=n!",
        "integral": r"\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}",
        "double_integral": r"\iint_D f(x,y)\,dx\,dy",
        "limit": r"\lim_{x\to0}\frac{\sin x}{x}=1",
        "derivative": r"\frac{\partial^2 u}{\partial t^2}=c^2\nabla^2u",
        "greek": r"\alpha+\beta+\gamma=\pi,\quad\Omega\subseteq\mathbb{R}",
        "sets": r"A\cup B=\{x\mid x\in A\lor x\in B\}",
        "logic": r"\forall x\in\mathbb{R},\quad x^2\geq0\implies P(x)",
        "trig": r"\sin^2\theta+\cos^2\theta=1",
        "log": r"\log(ab)=\log a+\log b,\quad\exp(0)=1",
        "bold": r"\mathbf{A}\boldsymbol{x}=\boldsymbol{b}",
        "fonts": r"\mathbb{R}\subset\mathbb{C},\quad\mathcal{F},\quad\mathfrak{g}",
        "accents": r"\hat{x}+\bar{y}+\tilde{z}+\dot{a}+\ddot{b}+\vec{v}",
        "wide_accents": r"\widehat{ABC}+\widetilde{xyz}+\overline{a+b}",
        "braces": r"\underbrace{a+\cdots+a}_{n\text{ times}}=na",
        "delimiters": r"\left(\frac{a}{b}\right)+\left[\sqrt{x}\right]",
        "short_delimiters": r"\left(x\right)+\left(y\right)",
        "absolute": r"\left|\frac{x}{y}\right|+\left\|v\right\|",
        "matrix": r"\begin{pmatrix}a&b\\c&d\end{pmatrix}",
        "bmatrix": r"\begin{bmatrix}1&0&0\\0&1&0\\0&0&1\end{bmatrix}",
        "determinant": r"\begin{vmatrix}a&b\\c&d\end{vmatrix}=ad-bc",
        "cases": r"f(x)=\begin{cases}x^2&x\geq0\\-x&x<0\end{cases}",
        "aligned": r"\begin{aligned}a&=b+c\\d&=e+f\end{aligned}",
        "gathered": r"\begin{gathered}a=b+c\\d=e+f\end{gathered}",
        "array": r"\begin{array}{cc}a&b\\c&d\end{array}",
        "text_english": r"P(A\mid B)=\frac{P(B\mid A)P(A)}{P(B)}\quad\text{Bayes rule}",
        "spacing": r"a\,b\:c\;d\!e\quad f\qquad g",
        "over_under": r"\overset{!}{=}\quad\underset{x\to0}{\lim}f(x)",
    }
    for name, tex in core.items():
        add("core", name, tex)
    extras = {
        "dfrac_tfrac": r"\dfrac{a}{b}+\tfrac{c}{d}",
        "operatorname": r"\operatorname{argmax}_{x\in X} f(x)",
        "operator_limits": r"\operatorname*{argmax}_{x\in X} f(x)",
        "smallmatrix": r"\left(\begin{smallmatrix}a&b\\c&d\end{smallmatrix}\right)",
        "alignedat": r"\begin{alignedat}{2}a&=b&\quad c&=d\\x&=y&z&=w\end{alignedat}",
        "align": r"\begin{align}a&=b+c\\d&=e+f\end{align}",
        "equation_tag": r"\begin{equation}E=mc^2\tag{1}\end{equation}",
        "gather": r"\begin{gather}a=b+c\\d=e+f\end{gather}",
        "multline": r"\begin{multline}a+b+c+d\\=e+f\end{multline}",
        "array_rules": r"\begin{array}{c|r}a&b\\\hline c&d\end{array}",
        "xrightarrow": r"A\xrightarrow{\text{a very long note}}B",
        "xleftrightarrow": r"A\xleftrightarrow[\text{below}]{\text{above}}B",
        "cancel": r"\frac{\cancel{x}y}{\cancel{x}}=y",
        "boxed": r"\boxed{E=mc^2}",
        "color": r"\textcolor{red}{x}+\color{blue}y",
        "mathscr": r"\mathscr{ABC}\quad\mathcal{ABC}",
        "substack": r"\sum_{\substack{i<j\\i,j\in I}}a_{ij}",
        "phantom": r"\sqrt{\phantom{\frac{a}{b}}x}+\vphantom{\frac{a}{b}}y",
        "newcommand": r"\newcommand{\R}{\mathbb{R}}x\in\R",
        "def": r"\def\foo#1{#1^2}\foo{x}",
        "unicode_math": "α+β≤γ∈ℝ",
        "text_chinese": r"x=1\quad\text{当且仅当中文条件成立}",
        "text_mixed": r"\text{损失 loss}=\sum_i(x_i-y_i)^2",
        "text_emoji": r"\text{😀}=1",
        "chemistry": r"\ce{2H2 + O2 -> 2H2O}",
        "physics": r"\dv{f}{x}+\qty(\frac{a}{b})",
        "unicode_literal": "x² + √y = ∞",
        "unicode_identifier": "损失=1",
    }
    for name, tex in extras.items():
        add("extended", name, tex)
    add("stress", "long_inline", "+".join(f"a_{{{i}}}" for i in range(1, 31)) + "=S", "inline")
    add("stress", "long_display", "+".join(f"a_{{{i}}}" for i in range(1, 31)) + "=S")
    add("stress", "large_matrix", r"\begin{pmatrix}" + r"\\".join("&".join(str(i*8+j) for j in range(8)) for i in range(8)) + r"\end{pmatrix}")
    add("stress", "deep_fraction", r"\frac{1}{"*12 + "x" + "}"*12)
    for name, tex in {
        "unknown": r"\unknownMacro{x}", "unclosed_group": r"\frac{a}{b",
        "missing_arg": r"\sqrt", "double_superscript": "x^2^3",
        "bad_environment": r"\begin{notreal}x\end{notreal}",
        "unmatched_right": r"x\right)",
    }.items():
        add("invalid", name, tex, valid=False)
    return rows


if __name__ == "__main__":
    import sys
    Path(sys.argv[1]).write_text(json.dumps(fixtures(), ensure_ascii=False, indent=2) + "\n")
