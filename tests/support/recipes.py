"""Behavior-specific setup/run steps; compilation and process policy live in Engine."""
import shutil
import sys


def run(engine, check, output):
    repo = engine.repo
    recipe = check.recipe
    if recipe == "harness":
        engine.command((sys.executable, "-m", "unittest", "discover", "-s", "tests/tooling", "-p", "test_*.py", "-v"))
        return
    if recipe == "syntax":
        engine.command((sys.executable, repo / "tests/support/syntax.py"))
        return
    if recipe in {"python", "node"}:
        engine.command((sys.executable if recipe == "python" else "node", repo / check.inputs[0]))
        return
    if recipe == "native-questions":
        responses = engine.outputs["functional:questions"]
        host = repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents/Resources/OMPSDKHost.js"
        engine.command(("bun", repo / "tests/native/questions_tests.mjs", responses, engine.package_root, host))
        return
    if recipe == "native-model-configuration":
        engine.command(("bun", repo / check.inputs[0], output, engine.omp[0], repo / check.inputs[1]))
        return
    if recipe == "native-sdk":
        engine.command(("bun", repo / check.inputs[0], output, engine.package_root))
        return
    if recipe == "benchmark-math":
        environment = {"OMP_GUI_VERIFICATION_OUTPUT": str(output)}
        engine.command(("bash", repo / "tests/benchmarks/math_renderers/setup.sh"), env=environment)
        engine.command((sys.executable, repo / "tests/benchmarks/math_renderers/run.py", "--phase", "all"), env=environment)
        return

    executable = engine.compile(check)
    if recipe == "mathjax-attachments":
        engine.command((sys.executable, repo / "tests/benchmarks/mathjax_attachments/run.py",
                        "--executable", executable, "--output", output), timeout=check.timeout)
    elif recipe == "lifecycle":
        engine.command((executable, "--metrics-disabled"))
        engine.command((executable, "--website-captures", output, "--fixture", repo / check.inputs[0]),
                       env={"OMP_GUI_PERFORMANCE": "1"})
    elif recipe == "capture":
        command = [executable, "--website-captures", output]
        if check.inputs:
            command.extend(("--fixture", repo / check.inputs[0]))
        engine.command(command)
    elif recipe in {"output", "math"}:
        engine.command((executable, output))
    elif recipe in {"markdown-preview", "benchmark-markdown"}:
        shutil.copyfile(executable.parent / "corpus.json", output / "corpus.json")
        if recipe == "benchmark-markdown":
            engine.command((sys.executable, repo / "tests/benchmarks/markdown_preview.py", engine.paper,
                            "--executable", executable, "--output", output))
        else:
            engine.command((executable, repo / "OMPGUI/Resources/MarkdownPreview", output,
                            *([engine.paper] if engine.paper else [])))
    elif recipe == "native-config":
        engine.command((executable, output, engine.omp[0], repo / check.inputs[0]))
    elif recipe == "native-mcp":
        engine.command((executable, output, engine.omp[0]))
    elif recipe in {"memory", "native-memory"}:
        engine.command((executable, output, *([engine.omp[0]] if recipe == "native-memory" else []), "--website-captures", output))
        if recipe == "memory":
            engine.command(("node", repo / check.inputs[0]))
        else:
            engine.command(("bun", repo / check.inputs[0], output, engine.package_root))
    elif recipe == "native-workers":
        engine.command((executable, output))
        engine.command(("bun", repo / "tests/native/workers_tests.mjs", output, engine.package_root))
    elif recipe == "native-approvals":
        native = repo / check.inputs[0]
        engine.command(("bun", native, "export", output, engine.package_root))
        engine.command((executable, output))
        engine.command(("bun", native, "verify", output, engine.package_root))
    elif recipe == "native-rpc":
        command = [sys.executable, repo / "tests/native/rpc_provider.py", "--helper", executable, "--output", output]
        for binary in engine.omp:
            command.extend(("--omp", binary))
        engine.command(command, timeout=check.timeout * len(engine.omp))
    elif recipe == "fast-write":
        app = repo / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"
        engine.command((executable, "export", app, output / "extension.ts"))
        engine.command(("bun", repo / "tests/native/fast_write_tests.mjs", output, engine.package_root / "src/index.ts"))
        engine.command((executable, "verify", output / "results.json"))
    elif recipe == "benchmark-lifecycle":
        engine.command((executable, "--metrics-disabled"))
        engine.command((sys.executable, repo / "tests/benchmarks/lifecycle.py", executable, output))
    elif recipe == "swift":
        engine.command((executable,))
    else:
        raise ValueError(f"Unknown recipe: {recipe}")
