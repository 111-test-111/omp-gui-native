import hljs from 'highlight.js/lib/common';
import cmake from 'highlight.js/lib/languages/cmake';
import dockerfile from 'highlight.js/lib/languages/dockerfile';
import latex from 'highlight.js/lib/languages/latex';
import julia from 'highlight.js/lib/languages/julia';
import matlab from 'highlight.js/lib/languages/matlab';
import dart from 'highlight.js/lib/languages/dart';
import scala from 'highlight.js/lib/languages/scala';
import groovy from 'highlight.js/lib/languages/groovy';
import powershell from 'highlight.js/lib/languages/powershell';
import dos from 'highlight.js/lib/languages/dos';
import elixir from 'highlight.js/lib/languages/elixir';
import erlang from 'highlight.js/lib/languages/erlang';
import haskell from 'highlight.js/lib/languages/haskell';
import fsharp from 'highlight.js/lib/languages/fsharp';
import clojure from 'highlight.js/lib/languages/clojure';
import lisp from 'highlight.js/lib/languages/lisp';
import scheme from 'highlight.js/lib/languages/scheme';
import ocaml from 'highlight.js/lib/languages/ocaml';
import nix from 'highlight.js/lib/languages/nix';
import protobuf from 'highlight.js/lib/languages/protobuf';
import verilog from 'highlight.js/lib/languages/verilog';
import vhdl from 'highlight.js/lib/languages/vhdl';
import fortran from 'highlight.js/lib/languages/fortran';
import x86asm from 'highlight.js/lib/languages/x86asm';

// Keep a deliberate offline selection instead of loading every vendor grammar.
for (const [name, grammar] of Object.entries({ cmake, dockerfile, latex, julia, matlab, dart, scala, groovy,
  powershell, dos, elixir, erlang, haskell, fsharp, clojure, lisp, scheme, ocaml, nix, protobuf,
  verilog, vhdl, fortran, x86asm })) hljs.registerLanguage(name, grammar);

// These small lexical grammars cover formats absent from the pinned vendor.
hljs.registerLanguage('hcl', h => ({
  keywords: 'resource data variable output locals module provider terraform required_providers backend dynamic for_each count depends_on lifecycle for in if true false null',
  contains: [h.HASH_COMMENT_MODE, h.C_LINE_COMMENT_MODE, h.C_BLOCK_COMMENT_MODE,
    h.QUOTE_STRING_MODE, h.NUMBER_MODE, { scope: 'attr', match: /\b[A-Za-z_][\w-]*(?=\s*=)/ }]
}));
hljs.registerLanguage('zig', h => ({
  keywords: 'align allowzero and anyerror anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern false fn for if inline noalias noinline nosuspend opaque or orelse packed pub resume return linksection struct suspend switch test threadlocal true try undefined union unreachable usingnamespace var volatile while',
  contains: [h.C_LINE_COMMENT_MODE, h.QUOTE_STRING_MODE, h.APOS_STRING_MODE, h.C_NUMBER_MODE,
    { scope: 'meta', match: /@[A-Za-z_][\w]*/ }]
}));
hljs.registerLanguage('bibtex', h => ({
  case_insensitive: true,
  contains: [h.COMMENT(/%/, /$/), { scope: 'keyword', match: /@[A-Za-z]+/ },
    { scope: 'attr', match: /\b[A-Za-z_][\w]*(?=\s*=)/ }, h.QUOTE_STRING_MODE,
    { begin: /=\s*\{/, end: /\}/, contains: [{ scope: 'string', begin: /\{/, end: /\}/, contains: ['self'] }], scope: 'string' },
    h.NUMBER_MODE]
}));

const aliases = {
  py: 'python', python2: 'python', python3: 'python', pyi: 'python',
  js: 'javascript', jsx: 'javascript', ecmascript: 'javascript', node: 'javascript', nodejs: 'javascript', mjs: 'javascript', cjs: 'javascript',
  ts: 'typescript', tsx: 'typescript', mts: 'typescript', cts: 'typescript',
  h: 'c', cc: 'cpp', 'c++': 'cpp', cplusplus: 'cpp', cxx: 'cpp', hpp: 'cpp', hxx: 'cpp', hh: 'cpp',
  cs: 'csharp', 'c#': 'csharp', m: 'objectivec', mm: 'objectivec', 'objective-c': 'objectivec', objc: 'objectivec', 'objective-c++': 'objectivec', objcpp: 'objectivec',
  kt: 'kotlin', kts: 'kotlin', rb: 'ruby', rs: 'rust', golang: 'go',
  sh: 'bash', shellscript: 'bash', 'shell-session': 'bash', console: 'bash', zsh: 'bash', fish: 'bash',
  json5: 'json', jsonc: 'json', jsonl: 'json', ndjson: 'json', xcstrings: 'json', toml: 'ini', yml: 'yaml', sass: 'scss',
  html: 'xml', htm: 'xml', xhtml: 'xml', svg: 'xml', vue: 'xml', svelte: 'xml', astro: 'xml', xsd: 'xml', xsl: 'xml', plist: 'xml',
  make: 'makefile', gnumakefile: 'makefile', mk: 'makefile', mak: 'makefile', docker: 'dockerfile', containerfile: 'dockerfile',
  tex: 'latex', ltx: 'latex', sty: 'latex', cls: 'latex', dtx: 'latex', ins: 'latex', bib: 'bibtex',
  cfg: 'ini', conf: 'ini', config: 'ini', properties: 'ini', editorconfig: 'ini', env: 'ini', dotenv: 'ini',
  terraform: 'hcl', tf: 'hcl', tfvars: 'hcl', gql: 'graphql', proto: 'protobuf', pl: 'perl', pm: 'perl', jl: 'julia', octave: 'matlab',
  phtml: 'php', sc: 'scala', gradle: 'groovy', ps1: 'powershell', pwsh: 'powershell', psm1: 'powershell', psd1: 'powershell', batch: 'dos', bat: 'dos', cmd: 'dos',
  ex: 'elixir', exs: 'elixir', erl: 'erlang', hrl: 'erlang', hs: 'haskell', lhs: 'haskell', 'f#': 'fsharp', fs: 'fsharp', fsx: 'fsharp', fsi: 'fsharp',
  clj: 'clojure', cljs: 'clojure', cljc: 'clojure', edn: 'clojure', elisp: 'lisp', el: 'lisp', lsp: 'lisp', scm: 'scheme', ss: 'scheme', ml: 'ocaml', mli: 'ocaml',
  v: 'verilog', sv: 'verilog', svh: 'verilog', vh: 'verilog', vhd: 'vhdl', f: 'fortran', for: 'fortran', f90: 'fortran', f95: 'fortran', f03: 'fortran', f08: 'fortran',
  asm: 'x86asm', assembly: 'x86asm', s: 'x86asm', patch: 'diff'
};
const filenames = {
  'cmakelists.txt': 'cmake', gemfile: 'ruby', rakefile: 'ruby', podfile: 'ruby', brewfile: 'ruby',
  '.env': 'ini', '.envrc': 'bash', '.bashrc': 'bash', '.bash_profile': 'bash', '.zshrc': 'bash', '.zprofile': 'bash', '.profile': 'bash',
  '.npmrc': 'ini', '.yarnrc': 'ini', '.editorconfig': 'ini', '.gitconfig': 'ini'
};
export function languageForInfo(info) {
  let name = (info || '').trim().split(/\s+/, 1)[0].toLowerCase().replace(/^[{]+|[}]+$/g, '').replace(/^language-/, '');
  if (!name || ['text', 'txt', 'plain', 'plaintext', 'none', 'nohighlight'].includes(name)) return null;
  const filename = name.split('/').at(-1);
  if (filenames[filename]) return filenames[filename];
  if (/^\.env\./.test(filename)) return 'ini';
  if (/^(?:gnu)?makefile(?:\.|$)/.test(filename)) return 'makefile';
  if (/^(?:dockerfile|containerfile)(?:\.|$)/.test(filename)) return 'dockerfile';
  name = name.replace(/^\./, '');
  if (aliases[name]) return aliases[name];
  if (hljs.getLanguage(name)) return name;
  const ext = filename.includes('.') ? filename.split('.').at(-1) : '';
  return aliases[ext] || (ext && hljs.getLanguage(ext) ? ext : null);
}
export { hljs };
