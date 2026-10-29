#!/bin/bash
set -euo pipefail
TASK_REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TASK_BENCH_ROOT="${OMP_GUI_VERIFICATION_OUTPUT:-$TASK_REPO_ROOT/build.noindex/math-renderer-evaluation}"
mkdir -p "$TASK_BENCH_ROOT/Sources" "$TASK_BENCH_ROOT/vendor"
cat > "$TASK_BENCH_ROOT/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MathRendererBenchmark", platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")],
    targets: [.executableTarget(name: "Benchmark", dependencies: [.product(name: "SwiftMath", package: "SwiftMath")], path: "Sources")],
    swiftLanguageModes: [.v5])
PACKAGE
for SOURCE in MarkdownMath; do
  ln -sf "$TASK_REPO_ROOT/OMPGUI/UI/Markdown/$SOURCE.swift" "$TASK_BENCH_ROOT/Sources/$SOURCE.swift"
done
ln -sf "$TASK_REPO_ROOT/tests/benchmarks/math_renderers/SwiftMathBaseline.swift" "$TASK_BENCH_ROOT/Sources/MathRendering.swift"
ln -sf "$TASK_REPO_ROOT/tests/benchmarks/math_renderers/Benchmark.swift" "$TASK_BENCH_ROOT/Sources/Benchmark.swift"
python3 "$TASK_REPO_ROOT/tests/benchmarks/math_renderers/corpus.py" "$TASK_BENCH_ROOT/corpus.json"
if [ ! -f "$TASK_BENCH_ROOT/vendor/temml-0.14.0.tgz" ]; then
  curl -fsSL https://registry.npmjs.org/temml/-/temml-0.14.0.tgz -o "$TASK_BENCH_ROOT/vendor/temml-0.14.0.tgz"
fi
python3 - "$TASK_BENCH_ROOT" <<'PY'
import base64, hashlib, pathlib, sys, tarfile
root=pathlib.Path(sys.argv[1])
archive=root/'vendor/temml-0.14.0.tgz'
assert base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode() == 'tz1LW/5IZpThK8c7ZpdTSH/n56eAj+ThirLieErtKxYC3EKCIiB4sKdRUehAgH+fQmvIKqMfP3gqTLBdLpy9zw==', 'Temml archive checksum mismatch'
with tarfile.open(archive) as bundle:
    for member in bundle.getmembers():
        assert not member.issym() and not member.islnk()
        assert not pathlib.PurePosixPath(member.name).is_absolute() and '..' not in pathlib.PurePosixPath(member.name).parts
    bundle.extractall(root/'vendor')
PY
python3 "$TASK_REPO_ROOT/tests/support/local_build.py" run \
  --product "$TASK_BENCH_ROOT/.build/release/Benchmark" "$TASK_REPO_ROOT" "$TASK_BENCH_ROOT/tmp" -- \
  swift build --package-path "$TASK_BENCH_ROOT" -c release
python3 - "$TASK_REPO_ROOT" "$TASK_BENCH_ROOT" <<'PY'
import pathlib, shutil, sys
repo,root=map(pathlib.Path,sys.argv[1:])
dist=root/'vendor/package/dist'
fonts=root/'.build/checkouts/SwiftMath/Sources/SwiftMath/mathFonts.bundle'
for name in ['Asana-Math.otf','latinmodern-math.otf','OFL.txt','GUST-FONT-LICENSE.txt','LICENSE']:
    shutil.copyfile(fonts/name,dist/name)
shutil.copyfile(repo/'tests/benchmarks/math_renderers/browser.js',dist/'browser.js')
shutil.copyfile(root/'vendor/package/contrib/mhchem/mhchem.min.js',dist/'mhchem.min.js')
shutil.copyfile(root/'vendor/package/contrib/physics/physics.js',dist/'physics.js')
shutil.copyfile(root/'vendor/package/contrib/copy-tex/copy-tex.min.js',dist/'copy-tex.min.js')
for font,css,old,new in [('local','Local',None,None),('asana','Asana','Asana-Math.woff2','Asana-Math.otf'),('latin','Latin-Modern','latinmodernmath.woff2','latinmodern-math.otf')]:
    style=(dist/f'Temml-{css}.css').read_text()
    if old: style=style.replace(old,new)
    # The chosen font loads before timing; keep default Temml spacing and layout.
    # Synthetic workloads contain no URLs; CSP also excludes network resources.
    html='''<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src 'self' 'unsafe-inline';style-src 'self' 'unsafe-inline';font-src 'self';img-src data:">
<style>CSS
body{margin:12px;font:15px -apple-system;color:#000;background:#fff;}
#content{width:696px;} .formula{margin:0 0 8px;} section{margin-bottom:16px;min-height:50px;}
.label{font:12px ui-monospace,monospace;color:#666;margin-bottom:5px;}
.example{line-height:normal;overflow:visible;}.fallback{font-family:monospace;}
body.visual section{height:90px;min-height:0;margin:0;}
body.visual .label{height:17px;margin:0 0 5px;}body.visual .example{height:68px;display:flex;align-items:center;justify-content:center;white-space:nowrap;overflow:hidden;}
body.visual .example>span{width:100%;text-align:center;}
body.inline-visual #content{width:1016px;display:flex;gap:40px;}body.inline-visual .column{flex:none;}
body.inline-visual .heading{height:33px;font:14px -apple-system;}body.inline-visual section{height:140px;min-height:0;margin:0;}
body.inline-visual .label{height:17px;margin:0 0 5px;}body.inline-visual .example{overflow-x:auto;overflow-y:hidden;}
body.dark{background:#1a1a1a;color:#fff;} body.dark .label{color:#aaa;}
</style><script src="temml.min.js"></script></head><body><main id="content"></main><script src="browser.js"></script></body></html>'''.replace('CSS',style)
    (dist/f'bench-{font}.html').write_text(html)
local=(dist/'bench-local.html').read_text()
(dist/'bench-local-extensions.html').write_text(local.replace('<script src="temml.min.js"></script>', '<script src="temml.min.js"></script><script src="mhchem.min.js"></script><script src="physics.js"></script>'))
(dist/'bench-local-copy.html').write_text(local.replace('<script src="temml.min.js"></script>', '<script src="temml.min.js"></script><script src="copy-tex.min.js"></script>'))
print(root/'.build/release/Benchmark')
PY
