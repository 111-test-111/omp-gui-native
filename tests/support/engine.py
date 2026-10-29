"""Shared preflight, compilation, bounded processes and machine-readable evidence."""
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid

from support import build_inputs
from support.local_build import clear_generated_quarantine, swiftpm_environment
from support.prepare import prepare


class CheckFailed(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code if code > 0 else 128 - code


class Engine:
    def __init__(self, repo, checks, omp=(), paper=None):
        self.repo = Path(repo).resolve()
        self.checks = checks
        self.omp = tuple(omp)
        self.paper = Path(paper).resolve() if paper else None
        self.base = self.repo / "build.noindex/verification"
        self.run_root = self.base / "runs" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
        self.outputs = {check.id: self.run_root / check.tier / check.area for check in checks}
        self.app_evidence = None
        self.tools = {}
        self.runtimes = []
        self.records = [{"id": check.id, "status": "not-run"} for check in checks]
        self.current = None

    def preflight(self):
        required = {tool for check in self.checks for tool in check.tools}
        if any(check.sources and check.recipe != "math" for check in self.checks):
            required.add("xcrun")
        for tool in sorted(required):
            resolved = shutil.which(tool)
            if not resolved:
                raise ValueError(f"Required tool not found: {tool}")
            self.tools[tool] = str(Path(resolved).resolve())
        if any(check.app for check in self.checks):
            self.app_evidence = build_inputs.verify(self.repo)
        if any(check.tier == "native" for check in self.checks):
            if not self.omp:
                raise ValueError("Native checks require --omp /absolute/path/to/omp (make: OMP=...).")
            if len(self.omp) > 1 and any(check.tier == "native" and check.area != "rpc" for check in self.checks):
                raise ValueError("Multiple --omp paths are supported only for native rpc; select other native areas per runtime.")
            binaries = []
            for binary in self.omp:
                path = Path(binary).expanduser()
                if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
                    raise ValueError(f"Require an absolute executable OMP path: {binary}")
                binaries.append(path.resolve())
            self.omp = tuple(dict.fromkeys(binaries))
            if any(check.recipe in {"native-questions", "native-approvals", "fast-write", "native-workers", "native-model-configuration", "native-sdk"} for check in self.checks):
                if not (self.package_root / "src/index.ts").is_file():
                    raise ValueError("Native SDK checks require an OMP installation containing src/index.ts beside its bin directory.")
        if any(check.recipe == "benchmark-markdown" for check in self.checks) and self.paper is None:
            raise ValueError("The Markdown preview benchmark requires --paper /absolute/path/to/paper.md (make: PAPER=...).")
        if self.paper and not self.paper.is_file():
            raise ValueError(f"Paper does not exist: {self.paper}")
        # Validate paths before starting any selected check.
        for check in self.checks:
            for path in (*check.sources, *check.inputs):
                if not path.startswith("@") and not (self.repo / path).exists():
                    raise ValueError(f"{check.id}: missing input {path}")
        for binary in self.omp if any(check.tier == "native" for check in self.checks) else ():
            (self.run_root / "tmp").mkdir(parents=True, exist_ok=True)
            try:
                version = subprocess.run((str(binary), "--version"), env=self.environment(self.run_root), cwd=self.repo,
                                         capture_output=True, text=True, timeout=15, check=True).stdout.strip()
            except (OSError, subprocess.SubprocessError) as error:
                raise ValueError(f"Cannot identify selected OMP executable {binary}: {error}") from error
            runtime = {"executable": str(binary), "version": version,
                       "sha256": build_inputs.digest_files(self.repo, (binary,))}
            sdk = binary.parent.parent / "src"
            if sdk.is_dir():
                runtime["sdk_source_sha256"] = build_inputs.digest_files(self.repo, (sdk,))
            self.runtimes.append(runtime)

    @property
    def package_root(self):
        return self.omp[0].parent.parent

    def environment(self, output):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("PI_", "OMP_")) and key not in
                       {"XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME"}}
        # OMP's getBaseConfigRoot joins this value to os.homedir; absolute
        # PI_CONFIG_DIR values produce a duplicated home prefix in native code.
        environment.update(PYTHONDONTWRITEBYTECODE="1", PYTHONPATH=str(self.repo / "tests"),
                           PI_CONFIG_DIR=os.path.relpath(output / "profile", Path.home()), PI_CODING_AGENT_DIR=str(output / "profile/agent"),
                           PI_PROFILE="default", OMP_PROFILE="default", TMPDIR=str(output / "tmp"))
        return environment

    def command(self, arguments, *, env=None, timeout=None):
        command = [str(arg) for arg in arguments]
        record = self.current
        limit = timeout if timeout is not None else record["timeout_seconds"]
        command_record = {"argv": command, "timeout_seconds": limit}
        record.setdefault("commands", []).append(command_record)
        print("  " + shlex.join(command), flush=True)
        output = self.outputs[record["id"]]
        environment = self.environment(output)
        environment.update(env or {})
        process = subprocess.Popen(command, cwd=self.repo, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                   text=True, errors="replace", start_new_session=True)
        try:
            text, _ = process.communicate(timeout=limit)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                text, _ = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                text, _ = process.communicate()
            with (output / "checks.log").open("a") as log:
                log.write(text)
            command_record.update(returncode=process.returncode, interrupted=isinstance(error, KeyboardInterrupt))
            if isinstance(error, KeyboardInterrupt):
                raise
            raise CheckFailed(f"Process exceeded {limit} seconds; owned process group terminated.", 124)
        command_record["returncode"] = process.returncode
        with (output / "checks.log").open("a") as log:
            log.write("$ " + shlex.join(command) + "\n" + text)
        if text:
            print(text, end="" if text.endswith("\n") else "\n", flush=True)
        if process.returncode:
            raise CheckFailed(f"Command failed ({process.returncode}); see {output / 'checks.log'}", process.returncode)
        return text

    def compile(self, check):
        signature = json.dumps({"sources": check.sources, "app": check.app, "prepare": check.prepare,
                                "math": check.recipe in {"math", "mathjax-attachments"}}, sort_keys=True)
        directory = self.base / "compiled" / hashlib.sha256(signature.encode()).hexdigest()[:16]
        directory.mkdir(parents=True, exist_ok=True)
        prepare(check.prepare, self.repo, directory)
        sources = [directory / name[1:] if name.startswith("@") else self.repo / name for name in check.sources]
        if check.recipe in {"math", "mathjax-attachments"}:
            return self.compile_math(directory, sources, minimum_macos="26.0" if check.recipe == "mathjax-attachments" else "14.0")
        cache = self.base / "module-cache"
        cache.mkdir(parents=True, exist_ok=True)
        executable = directory / "checks"
        command = ["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-module-cache-path", cache]
        if check.prepare == "markdown-preview":
            command.append("-O")
        if check.app:
            command.extend(("-I", self.repo / build_inputs.PRODUCTS))
            # The app's Swift package modules refer to these two Clang modules.
            # Resolve the same checked/prepared headers used by this Dev build;
            # adding search paths does not load or initialize Chromium.
            cef_headers = self.repo / "build.noindex/browser/dependencies/CefSwift/Sources/CCef/include"
            cef_appkit = self.repo / "build.noindex/development/Build/Intermediates.noindex/GeneratedModuleMaps/CCefAppKit.modulemap"
            if cef_headers.is_dir() and cef_appkit.is_file():
                command.extend(("-I", cef_headers, "-Xcc", "-fmodule-map-file=" + str(cef_appkit)))
        command.extend(sources)
        inputs = list(sources)
        if check.app:
            library = self.repo / build_inputs.LIBRARY
            code = library.parent
            command.extend((library, "-Xlinker", "-rpath", "-Xlinker", code))
            inputs.extend((library, self.repo / build_inputs.PRODUCTS / "OMPGUI.swiftmodule"))
        command.extend(("-o", executable))
        if "swift_version" not in self.tools:
            self.tools["swift_version"] = self.command(("xcrun", "swiftc", "--version"), timeout=15).strip()
        fingerprint = hashlib.sha256((signature + self.tools["swift_version"] + str(self.tools.get("xcrun")) +
                                     build_inputs.digest_files(self.repo, inputs)).encode()).hexdigest()
        stamp = directory / "build.json"
        try:
            cached = json.loads(stamp.read_text())
            reusable = (cached["inputs_sha256"] == fingerprint and executable.is_file()
                        and cached["executable_sha256"] == build_inputs.digest_files(self.repo, (executable,)))
        except (OSError, ValueError, KeyError):
            reusable = False
        if not reusable:
            stamp.unlink(missing_ok=True)
            self.command(command)
            stamp.write_text(json.dumps({"inputs_sha256": fingerprint,
                                        "executable_sha256": build_inputs.digest_files(self.repo, (executable,))}))
        else:
            print(f"  Reusing compiled helper: {executable}", flush=True)
        # Only compiler outputs with current source/binary fingerprints are trusted.
        clear_generated_quarantine(self.repo, executable)
        return executable

    def compile_math(self, directory, sources, minimum_macos="14.0"):
        target = directory / "Sources/Checks"
        target.mkdir(parents=True, exist_ok=True)
        for source in sources:
            link = target / ("main.swift" if source.name.endswith("_tests.swift") else source.name)
            if not link.is_symlink() or link.resolve() != source.resolve():
                link.unlink(missing_ok=True)
                link.symlink_to(source)
        manifest = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MathChecks", platforms: [.macOS("MINIMUM_MACOS")], dependencies: [.package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")], targets: [.executableTarget(name: "Checks", dependencies: [.product(name: "SwiftMath", package: "SwiftMath")])])
'''.replace("MINIMUM_MACOS", minimum_macos)
        package = directory / "Package.swift"
        if not package.exists() or package.read_text() != manifest:
            package.write_text(manifest)
        self.command(("swift", "build", "--package-path", directory, "-c", "release"),
                     env=swiftpm_environment(self.repo, directory / "tmp"), timeout=300)
        executable = directory / ".build/release/Checks"
        clear_generated_quarantine(self.repo, executable)
        return executable

    def save_report(self, status):
        report = {"schema": 1, "status": status, "date": datetime.now(timezone.utc).isoformat(),
                  "platform": platform.platform(), "python": sys.version, "tools": self.tools,
                  "app_build": self.app_evidence, "runtimes": self.runtimes, "checks": self.records}
        if self.paper:
            report["paper"] = {"path": str(self.paper)}
            if self.paper.is_file():
                report["paper"]["sha256"] = build_inputs.digest_files(self.repo, (self.paper,))
        (self.run_root / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    def execute(self):
        from support.recipes import run

        self.run_root.mkdir(parents=True)
        status = "failed"
        try:
            self.preflight()
            for check, record in zip(self.checks, self.records):
                self.current = record
                output = self.outputs[check.id]
                (output / "tmp").mkdir(parents=True)
                (output / "profile/agent").mkdir(parents=True)
                record.update(status="running", timeout_seconds=check.timeout, definition=asdict(check), output=str(output))
                # Reports fingerprint declared production/test inputs, including
                # fixtures and the runner itself, without treating HEAD as truth.
                paths = [name for name in (*check.sources, *check.inputs) if not name.startswith("@")]
                paths += ["tests/run.py", "tests/catalog.py", "tests/support"]
                start = time.monotonic()
                try:
                    record["inputs_sha256"] = build_inputs.digest_files(self.repo, paths)
                    if check.app:
                        record["app_binary_sha256"] = self.app_evidence["binary_sha256"]
                    print(f"[{check.id}] {check.description}", flush=True)
                    run(self, check, output)
                    record["status"] = "passed"
                except BaseException:
                    record["status"] = "failed"
                    raise
                finally:
                    record["seconds"] = round(time.monotonic() - start, 3)
                    self.save_report("running" if record["status"] == "passed" else "failed")
                print(f"PASS {check.id} ({record['seconds']}s)", flush=True)
            status = "passed"
        except KeyboardInterrupt:
            status = "interrupted"
            raise
        except (ValueError, OSError, CheckFailed) as error:
            # Preflight failures also leave an explicit, non-passing report.
            self.records.append({"id": "runner", "status": "failed", "error": str(error)})
            raise
        finally:
            self.save_report(status)
            print(f"Report: {self.run_root / 'report.json'}", flush=True)
