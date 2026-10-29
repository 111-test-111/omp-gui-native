import Foundation

/// A deliberately bounded lexical highlighter shared by source previews, chat
/// fences and read-tool output. It never retains a document or creates UI values.
enum PreviewSyntaxHighlighter {
    enum Token: Sendable { case comment, string, keyword, number, type, attribute }
    struct Span: Sendable { let range: NSRange; let token: Token }
    static let maximumUTF16Length = 262_144
    static let maximumSpans = 20_000

    private static let supportedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "cs", "java", "kt", "kts", "js", "jsx", "ts", "tsx",
        "json", "jsonc", "py", "rb", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml", "rs", "go", "css", "scss",
        "html", "htm", "xml", "svg", "md", "sql", "make", "cmake", "dockerfile", "tex", "bib", "ini", "env", "tf", "nix",
        "graphql", "proto", "lua", "pl", "r", "jl", "matlab", "php", "dart", "scala", "groovy", "ps1", "bat", "ex",
        "erl", "hs", "fs", "clj", "lisp", "scm", "ml", "zig", "v", "vhdl", "f90", "asm", "diff",
    ]
    private static let aliases = [
        "python": "py", "python2": "py", "python3": "py", "pyi": "py",
        "javascript": "js", "ecmascript": "js", "node": "js", "nodejs": "js", "mjs": "js", "cjs": "js",
        "typescript": "ts", "mts": "ts", "cts": "ts",
        "c++": "cpp", "cplusplus": "cpp", "cxx": "cpp", "hxx": "hpp", "hh": "hpp",
        "c#": "cs", "csharp": "cs", "objective-c": "m", "objc": "m", "objectivec": "m", "objective-c++": "mm", "objcpp": "mm",
        "kotlin": "kt", "ruby": "rb", "rust": "rs", "golang": "go",
        "shell": "sh", "shellscript": "sh", "shell-session": "sh", "console": "sh",
        "json5": "jsonc", "jsonl": "json", "ndjson": "json", "xcstrings": "json", "sass": "scss", "less": "css",
        "xhtml": "html", "vue": "html", "svelte": "html", "astro": "html", "xsd": "xml", "xsl": "xml", "plist": "xml",
        "markdown": "md", "mdown": "md", "mkd": "md", "mdx": "md",
        "makefile": "make", "gnumakefile": "make", "mk": "make", "mak": "make", "docker": "dockerfile", "containerfile": "dockerfile",
        "latex": "tex", "ltx": "tex", "sty": "tex", "cls": "tex", "dtx": "tex", "ins": "tex", "bibtex": "bib",
        "cfg": "ini", "conf": "ini", "config": "ini", "properties": "ini", "editorconfig": "ini", "dotenv": "env",
        "terraform": "tf", "hcl": "tf", "tfvars": "tf", "gql": "graphql", "protobuf": "proto",
        "perl": "pl", "pm": "pl", "julia": "jl", "octave": "matlab", "phtml": "php", "sc": "scala", "gradle": "groovy",
        "powershell": "ps1", "pwsh": "ps1", "psm1": "ps1", "psd1": "ps1", "batch": "bat", "cmd": "bat", "dos": "bat",
        "elixir": "ex", "exs": "ex", "erlang": "erl", "hrl": "erl", "haskell": "hs", "lhs": "hs",
        "f#": "fs", "fsharp": "fs", "fsx": "fs", "fsi": "fs", "clojure": "clj", "cljs": "clj", "cljc": "clj", "edn": "clj",
        "elisp": "lisp", "el": "lisp", "lsp": "lisp", "scheme": "scm", "ss": "scm", "ocaml": "ml", "mli": "ml",
        "verilog": "v", "sv": "v", "svh": "v", "vh": "v", "vhd": "vhdl", "fortran": "f90", "f": "f90", "for": "f90",
        "f95": "f90", "f03": "f90", "f08": "f90", "assembly": "asm", "x86asm": "asm", "s": "asm", "patch": "diff",
    ]
    private static let filenames = [
        "makefile": "make", "gnumakefile": "make", "cmakelists.txt": "cmake", "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "gemfile": "rb", "rakefile": "rb", "podfile": "rb", "brewfile": "rb", ".env": "env", ".envrc": "sh",
        ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "zsh", ".zprofile": "zsh", ".profile": "sh",
        ".npmrc": "ini", ".yarnrc": "ini", ".editorconfig": "ini", ".gitconfig": "ini",
    ]

    /// Filename recognition matters for Makefile, Dockerfile and dotfiles, whose
    /// final path extension either does not exist or describes a local variant.
    static func languageExtension(forFilePath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let language = filenames[name] { return language }
        if name.hasPrefix(".env.") { return "env" }
        for (prefix, language) in [("makefile.", "make"), ("gnumakefile.", "make"), ("dockerfile.", "dockerfile"), ("containerfile.", "dockerfile")] {
            if name.hasPrefix(prefix) { return language }
        }
        let ext = (name as NSString).pathExtension
        if let language = aliases[ext] { return language }
        return supportedExtensions.contains(ext) ? ext : nil
    }

    /// Explicit plaintext and unknown languages stay uncolored; there is no
    /// guessing from source content or running a source file to identify it.
    static func languageExtension(forFenceInfo info: String?) -> String? {
        guard let first = info?.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        var name = String(first).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if name.hasPrefix("language-") { name = String(name.dropFirst("language-".count)) }
        if let language = languageExtension(forFilePath: name) { return language }
        if name.hasPrefix(".") { name.removeFirst() }
        if let language = aliases[name] { return language }
        if supportedExtensions.contains(name) { return name }
        return languageExtension(forFilePath: name)
    }

    private static let quoted = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:[\s\S]|$)|[^'\\])*(?:'|$)"#
    private static let multilineQuoted = #""""(?:\\(?:[\s\S]|$)|(?!""")[\s\S])*(?:"""|$)|'''(?:\\(?:[\s\S]|$)|(?!''')[\s\S])*(?:'''|$)|"# + quoted + #"|\x60(?:\\(?:[\s\S]|$)|[^\x60\\])*(?:\x60|$)"#
    private static let commonKeywords: Set<String> = Set((
        "actor and any as assert async await associatedtype break case catch class const continue declare def default defer del delete do done elif else enum esac except export extends extension false fi final finally for from func function global guard if implements import in init instanceof interface internal is keyof lambda let match mut namespace new nil nonlocal null None not of open operator or override package pass private protected protocol public raise range readonly repeat return satisfies self Self some static struct super switch then throw throws trait true True False try type typealias typeof var void when while with yield select SELECT FROM WHERE JOIN AND OR INSERT UPDATE DELETE CREATE TABLE ORDER BY"
    ).split(separator: " ").map(String.init))

    private struct Rules {
        var comment = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|$)"#
        var string = multilineQuoted
        var keyword = #"(?!)"#
        var attribute = #"@[A-Za-z_][A-Za-z_0-9]*"#
        var type = #"(?!)"#
        var word = #"\b[A-Za-z_][A-Za-z_0-9]*\b"#
        var keywords = commonKeywords
        var caseInsensitiveWords = false
        var capitalizedTypes = true

        mutating func words(_ source: String, insensitive: Bool = false) {
            keywords = Set(source.split(separator: " ").map(String.init))
            caseInsensitiveWords = insensitive
        }
    }

    private static func rules(for language: String) -> Rules {
        var rules = Rules()
        switch language {
        case "py", "rb", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml", "pl", "r":
            rules.comment = #"#[^\r\n]*"#
            if language == "pl" { rules.keywords.formUnion(["sub", "my", "our", "use", "unless", "elsif", "foreach", "undef"]) }
            if language == "r" { rules.keywords.formUnion(["TRUE", "FALSE", "NA", "NULL", "Inf", "NaN", "next"]) }
        case "html", "htm", "xml", "svg":
            rules.comment = #"<!--[\s\S]*?(?:-->|$)"#
            rules.keyword = #"</?[A-Za-z][A-Za-z0-9:_-]*"#
            rules.attribute = #"[A-Za-z_:][A-Za-z0-9:_.-]*(?=\s*=)"#
        case "md":
            rules.comment = #"<!--[\s\S]*?(?:-->|$)"#
            rules.string = #"(?m:^[ \t]{0,3}(?<ticks>\x60{3,})[^\r\n]*\r?\n)[\s\S]*?(?:(?m:^[ \t]{0,3}\k<ticks>\x60*[ \t]*(?=\r|\n|$))|$)|(?m:^[ \t]{0,3}(?<tildes>~{3,})[^\r\n]*\r?\n)[\s\S]*?(?:(?m:^[ \t]{0,3}\k<tildes>~*[ \t]*(?=\r|\n|$))|$)|(?<inlineTicks>\x60+)[^\r\n]*?\k<inlineTicks>"#
            rules.keyword = #"\\[^A-Za-z0-9\s]|(?m:^[ \t]{0,3}#{1,6}(?:[ \t]+[^\r\n]*|$)|^[ \t]{0,3}(?:={2,}|-{2,})[ \t]*(?=\r|\n|$))"#
            rules.attribute = #"!?\[[^\]\r\n]*\](?:\([^\r\n)]*\)|\[[^\]\r\n]*\])|(?m:^[ \t]*(?:>[ \t]?|[-+*][ \t]+|[0-9]+[.)][ \t]+))"#
            rules.type = #"\*\*(?=\S)[^*\r\n]+\*\*|__(?=\S)[^_\r\n]+__|~~(?=\S)[^~\r\n]+~~|(?<!\*)\*(?=\S)[^*\r\n]+\*(?!\*)|(?<!\w)_(?=\S)[^_\r\n]+_(?!\w)"#
            rules.word = #"(?!)"#
        case "css", "scss":
            rules.attribute = #"[A-Za-z_-][A-Za-z0-9_-]*(?=\s*:)"#
            rules.type = #"[.#][A-Za-z_][A-Za-z0-9_-]*"#
        case "sql": rules.comment += #"|--[^\r\n]*"#
        case "rs":
            // A lifetime is not an unterminated character literal.
            rules.string = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\(?:u\{[0-9a-fA-F_]+\}|x[0-9a-fA-F]{2}|[\s\S])|[^'\\])'"#
        case "make":
            rules.comment = #"#[^\r\n]*"#
            rules.keyword = #"(?m:^\.[A-Z_]+(?=:))"#
            rules.attribute = #"\$\((?:[^()\r\n]|\([^()\r\n]*\))*\)|\$\{[^}\r\n]*\}|\$[@%<?^+*|]|\b[A-Za-z_][A-Za-z0-9_.-]*(?=[ \t]*(?:[?:+!]?=|::=))"#
            rules.type = #"(?m:^(?!\t)[^\s#:=][^#:=\r\n]*(?=:(?!=)))"#
            rules.words("include sinclude define endef ifdef ifndef ifeq ifneq else endif override export unexport private vpath undefine")
        case "cmake":
            rules.comment = #"#\[(?<commentEquals>=*)\[[\s\S]*?(?:\]\k<commentEquals>\]|$)|#[^\r\n]*"#
            rules.string = #"\[(?<stringEquals>=*)\[[\s\S]*?(?:\]\k<stringEquals>\]|$)|"(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)"#
            rules.keyword = #"\b[A-Za-z_][A-Za-z0-9_]*(?=[ \t]*\()"#
            rules.attribute = #"\$(?:ENV|CACHE)?\{[^}\r\n]*\}"#
        case "dockerfile":
            rules.comment = #"(?m:^[ \t]*#[^\r\n]*)"#
            rules.attribute = #"\$\{[^}\r\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|--[A-Za-z][A-Za-z-]*"#
            rules.words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as", insensitive: true)
        case "tex":
            rules.comment = #"%[^\r\n]*"#
            rules.string = #"\\begin\{verbatim\*?\}[\s\S]*?(?:\\end\{verbatim\*?\}|$)|\\verb\*?(?<delimiter>[^\sA-Za-z])[\s\S]*?(?:\k<delimiter>|$)"#
            rules.keyword = #"\\(?:[A-Za-z@]+\*?|[^\s])"#
            rules.attribute = #"#[1-9]"#
            rules.word = #"(?!)"#
        case "bib":
            rules.comment = #"%[^\r\n]*|(?i:@comment\s*\{[^}]*\})"#
            rules.string = quoted + #"|=[ \t]*\{(?:[^{}]|\{[^{}]*\})*(?:\}|$)"#
            rules.keyword = #"@[A-Za-z]+"#
            rules.attribute = #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*=)"#
        case "ini", "env":
            rules.comment = #"[;#][^\r\n]*"#
            rules.string = quoted
            rules.type = #"(?m:^[ \t]*\[[^\]\r\n]+\])"#
            rules.attribute = #"(?m:^[ \t]*[A-Za-z_][A-Za-z0-9_.-]*(?=[ \t]*[=:]))"#
            rules.words("true false on off yes no null", insensitive: true)
            rules.capitalizedTypes = false
        case "tf", "nix":
            rules.comment += #"|#[^\r\n]*"#
            rules.attribute = #"\b[A-Za-z_][A-Za-z0-9_-]*(?=\s*=)"#
            rules.words(language == "tf" ? "resource data variable output locals module provider terraform required_providers backend dynamic for_each count depends_on lifecycle for in if true false null" : "let in with rec inherit if then else assert or import builtins true false null")
        case "graphql":
            rules.comment = #"#[^\r\n]*"#
            rules.attribute = #"\$[A-Za-z_][A-Za-z0-9_]*|@[A-Za-z_][A-Za-z0-9_]*"#
            rules.words("query mutation subscription fragment on schema scalar type interface union enum input extend implements directive repeatable true false null")
        case "proto":
            rules.words("syntax import weak public package option message enum service rpc returns stream extend extensions reserved repeated optional required oneof map double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes true false")
        case "lua":
            rules.comment = #"--\[(?<commentEquals>=*)\[[\s\S]*?(?:\]\k<commentEquals>\]|$)|--[^\r\n]*"#
            rules.string = #"\[(?<stringEquals>=*)\[[\s\S]*?(?:\]\k<stringEquals>\]|$)|"# + quoted
            rules.words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while")
        case "jl":
            rules.comment = #"#=[\s\S]*?(?:=#|$)|#[^\r\n]*"#
            rules.keywords.formUnion(["begin", "end", "baremodule", "module", "using", "where", "mutable", "abstract", "primitive", "nothing", "missing"])
        case "matlab":
            rules.comment = #"%\{[\s\S]*?(?:%\}|$)|%[^\r\n]*"#
            // A transpose apostrophe follows an expression; it is not a quote.
            rules.string = #""(?:""|[^"])*(?:"|$)|(?<![A-Za-z0-9_.)\]}])'(?:''|[^'\r\n])*(?:'|(?=\r|\n)|$)"#
            rules.words("break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while properties methods events enumeration")
        case "php":
            rules.comment += #"|#[^\r\n]*"#
            rules.attribute = #"\$[A-Za-z_][A-Za-z0-9_]*"#
            rules.keywords.formUnion(["echo", "require", "require_once", "include", "include_once", "use", "fn", "foreach", "elseif"])
        case "dart": rules.keywords.formUnion(["abstract", "dynamic", "factory", "get", "set", "late", "mixin", "required", "covariant", "on", "sync"])
        case "scala": rules.keywords.formUnion(["abstract", "implicit", "lazy", "object", "sealed", "val", "given", "using", "end", "derives"])
        case "groovy": rules.keywords.formUnion(["abstract", "boolean", "byte", "char", "double", "float", "int", "long", "short", "synchronized", "transient", "volatile"])
        case "ps1":
            rules.comment = #"<#[\s\S]*?(?:#>|$)|#[^\r\n]*"#
            rules.attribute = #"\$\{[^}\r\n]*\}|\$[A-Za-z_][A-Za-z0-9_:]*|-[A-Za-z][A-Za-z0-9]*"#
            rules.words("begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow", insensitive: true)
        case "bat":
            rules.comment = #"(?im:^[ \t]*@?(?:rem\b|::)[^\r\n]*)"#
            rules.attribute = #"%[^%\r\n]+%|%%?[A-Za-z0-9*]|![A-Za-z_][A-Za-z0-9_]*!"#
            rules.words("call cd chdir cls copy del do echo else endlocal equ errorlevel exist exit for geq goto gtr if leq lss mkdir move neq not path pause popd pushd rem ren rmdir set setlocal shift start type ver", insensitive: true)
        case "ex":
            rules.comment = #"#[^\r\n]*"#
            rules.keywords.formUnion(["defmodule", "defp", "defmacro", "defstruct", "defprotocol", "defimpl", "end", "use", "alias", "require", "fn", "cond", "unless", "receive", "after", "rescue"])
        case "erl":
            rules.comment = #"%[^\r\n]*"#
            rules.words("after begin case catch cond end fun if let of query receive try when andalso orelse bnot not div rem band and bor bxor bsl bsr or xor true false")
        case "hs":
            rules.string = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])'"#
            rules.comment = #"\{-[\s\S]*?(?:-\}|$)|--[^\r\n]*"#
            rules.words("case class data default deriving do else family forall foreign hiding if import in infix infixl infixr instance let module newtype of qualified then type where")
        case "fs", "ml":
            rules.comment = #"\(\*[\s\S]*?(?:\*\)|$)|//[^\r\n]*"#
            // Type variables ('a) must not hide the rest of an expression.
            rules.string = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)|'(?:\\[\s\S]|[^'\\])'"#
            rules.keywords.formUnion(["begin", "end", "fun", "module", "mutable", "rec", "use", "val", "of", "then"])
        case "clj", "lisp", "scm":
            rules.comment = #"#\|[\s\S]*?(?:\|#|$)|;[^\r\n]*"#
            // Apostrophe and backtick quote forms, not string literals.
            rules.string = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)"#
            rules.word = #"[A-Za-z_*+!?-][A-Za-z0-9_*+!?/-]*"#
            rules.words("def defn defmacro defonce defprotocol defrecord deftype defstruct define define-syntax define-macro defun defvar defparameter lambda let let* letrec loop recur fn if if-not when unless cond case do begin end set! setq quote quasiquote unquote ns require use import in true false nil and or not")
        case "zig":
            rules.keywords.formUnion(["fn", "pub", "extern", "undefined", "align", "allowzero", "anyerror", "anyframe", "anytype", "asm", "callconv", "comptime", "errdefer", "error", "noalias", "opaque", "orelse", "packed", "resume", "suspend", "test", "threadlocal", "unreachable", "usingnamespace", "volatile"])
        case "v":
            rules.keyword = #"\x60[A-Za-z_][A-Za-z0-9_]*"#
            rules.string = #""(?:\\(?:[\s\S]|$)|[^"\\])*(?:"|$)"#
            rules.words("always always_comb always_ff always_latch assign automatic begin bit byte case casex casez class clocking const constraint cover default disable do else end endcase endclass endfunction endgenerate endinterface endmodule endpackage endtask enum event final for force foreach forever fork function generate genvar if initial inout input int integer interface join localparam logic longint module output package packed parameter program property protected rand reg repeat return shortint signed static string struct task time typedef union unsigned var virtual void wait while wire")
        case "vhdl":
            rules.comment = #"--[^\r\n]*"#
            rules.words("architecture array assert begin block body buffer bus case component configuration constant disconnect downto else elsif end entity exit file for function generate generic group guarded if impure in inertial inout is label library linkage literal loop map mod nand new next nor not null of on open or others out package port postponed procedure process pure range record register reject rem report return rol ror select severity shared signal sla sll sra srl subtype then to transport type unaffected units until use variable wait when while with xnor xor", insensitive: true)
        case "f90":
            rules.comment = #"![^\r\n]*"#
            rules.words("allocate allocatable assignment associate backspace block call case character class close common complex contains continue cycle data deallocate default dimension do double else elseif elsewhere end enddo endif entry enum equivalence exit external final flush forall format function generic goto if implicit import in include inout integer intent interface intrinsic logical module namelist none nullify only open operator optional out parameter pause pointer precision print private procedure program protected public pure read real recursive result return rewind save select sequence stop subroutine target then type use value volatile wait where while write", insensitive: true)
        case "asm":
            rules.comment = #"[;#][^\r\n]*"#
            rules.words("add and call cmp db dd dec dq dw end equ extern global inc int ja jb je jg jl jmp jne lea mov mul nop not or pop push ret section shl shr sub test times xor", insensitive: true)
        case "diff":
            rules.comment = #"(?m:^(?:diff |index |--- |\+\+\+ |\\ No newline)[^\r\n]*)"#
            rules.string = #"(?m:^\+(?!\+\+)[^\r\n]*)"#
            rules.keyword = #"(?m:^-(?!--)[^\r\n]*)"#
            rules.type = #"(?m:^@@[^\r\n]*)"#
            rules.attribute = #"(?!)"#
            rules.word = #"(?!)"#
        default: break
        }
        return rules
    }

    static func spans(in source: String, extension ext: String) -> [Span] {
        guard !Task.isCancelled, let language = languageExtension(forFenceInfo: ext) else { return [] }
        let rules = rules(for: language)
        let prefix = String(decoding: source.utf16.prefix(maximumUTF16Length), as: UTF16.self)
        let text = prefix as NSString
        let pattern = "(?<comment>\(rules.comment))|(?<string>\(rules.string))|(?<keyword>\(rules.keyword))|(?<attribute>\(rules.attribute))|(?<type>\(rules.type))|(?<number>\\b(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\\.[0-9]+)?)\\b)|(?<word>\(rules.word))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [Span] = []
        let tokens: [(String, Token)] = [("comment", .comment), ("string", .string), ("keyword", .keyword), ("attribute", .attribute), ("type", .type), ("number", .number)]
        // One combined pass protects strings/comments from overlapping tokens.
        regex.enumerateMatches(in: prefix, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard !Task.isCancelled, result.count < maximumSpans else { stop.pointee = true; return }
            guard let match else { return }
            for (name, token) in tokens {
                let range = match.range(withName: name)
                if range.location != NSNotFound { result.append(Span(range: range, token: token)); return }
            }
            let range = match.range(withName: "word")
            if range.location != NSNotFound {
                let word = text.substring(with: range)
                if rules.keywords.contains(rules.caseInsensitiveWords ? word.lowercased() : word) {
                    result.append(Span(range: range, token: .keyword))
                } else if rules.capitalizedTypes && word.first?.isUppercase == true {
                    result.append(Span(range: range, token: .type))
                }
            }
        }
        return result
    }
}
