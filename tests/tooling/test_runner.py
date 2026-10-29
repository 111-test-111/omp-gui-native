"""Runner contracts using temporary repositories and subprocess doubles only.

These tests never compile the app, import an installed OMP, or launch a GUI.
"""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from catalog import Check, plan, registry
import run as cli
from support import build_inputs
from support.engine import CheckFailed, Engine
from support.prepare import prepare
from support.recipes import run as run_recipe


class SelectionTests(unittest.TestCase):
    def test_no_selection_only_lists(self):
        with patch.object(cli, "Engine") as engine, redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main([]), 0)
        engine.assert_not_called()

    def test_unknown_area_rejects_entire_request(self):
        with patch.object(cli, "Engine") as engine, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                cli.main(["rpc", "typo"])
        self.assertEqual(error.exception.code, 2)
        engine.assert_not_called()

    def test_plan_has_no_tool_or_build_dependency(self):
        with patch.object(cli, "Engine") as engine, redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--dry-run", "--tier", "native", "--omp", "/missing/omp", "questions"]), 0)
        engine.assert_not_called()

    def test_preserve_order_and_deduplicate_dependencies(self):
        checks = {
            "native:a": Check("a", "A", tier="native", dependencies=("functional:shared",)),
            "native:b": Check("b", "B", tier="native", dependencies=("functional:shared",)),
            "functional:shared": Check("shared", "shared"),
        }
        self.assertEqual([item.id for item in plan(["b", "a", "b"], "native", checks)],
                         ["functional:shared", "native:b", "native:a"])

    def test_detect_cycle(self):
        checks = {"functional:a": Check("a", "A", dependencies=("functional:b",)),
                  "functional:b": Check("b", "B", dependencies=("functional:a",))}
        with self.assertRaisesRegex(ValueError, "cycle"):
            plan(["a"], checks=checks)

    def test_detect_missing_dependency(self):
        with self.assertRaisesRegex(ValueError, "Missing dependency"):
            plan(["a"], checks={"functional:a": Check("a", "A", dependencies=("functional:absent",))})

    def test_expensive_area_requires_its_explicit_tier(self):
        with self.assertRaisesRegex(ValueError, "Unknown checks"):
            plan(["fast-write"])
        self.assertEqual([item.id for item in plan(["fast-write"], "native")], ["native:fast-write"])


class RegistryTests(unittest.TestCase):
    repo = Path(__file__).resolve().parents[2]

    def test_paths_and_extracted_sources_exist(self):
        for check in registry().values():
            with self.subTest(check=check.id), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                prepare(check.prepare, self.repo, output)
                for name in (*check.sources, *check.inputs):
                    path = output / name[1:] if name.startswith("@") else self.repo / name
                    self.assertTrue(path.exists(), f"{check.id}: {path}")

    def test_every_automated_test_file_is_registered(self):
        declared = {name for check in registry().values() for name in (*check.sources, *check.inputs)}
        actual = {str(path.relative_to(self.repo)) for folder in ("functional", "native", "benchmarks")
                  for path in (self.repo / "tests" / folder).rglob("*_tests.*")}
        self.assertEqual(actual - declared, set(), "Register new checks; orphan tests do not count as coverage")

    def test_dependencies_cannot_sneak_in_expensive_tiers(self):
        allowed = {"static": {"static"}, "functional": {"static", "functional"},
                   "native": {"static", "functional", "native"}, "benchmark": {"static", "functional", "benchmark"}}
        for check in registry().values():
            with self.subTest(check=check.id):
                selected = plan([check.area], check.tier)
                self.assertTrue(all(item.tier in allowed[check.tier] for item in selected))
                self.assertEqual(len(selected), len({item.id for item in selected}))

    def test_legacy_wrappers_are_removed(self):
        self.assertEqual(list((self.repo / "scripts").glob("check_*")), [])
        self.assertFalse((self.repo / "scripts/verify.py").exists())


class TemporaryRepoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="verify spaces $literal ")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        for path in ("tests/support", "OMPGUI", "config", "OMPGUI.xcodeproj", "scripts"):
            (self.repo / path).mkdir(parents=True)
        for path in ("tests/run.py", "tests/catalog.py", "OMPGUI/source.swift", "config/dev.xcconfig",
                     "project.yml", "scripts/develop.sh", "scripts/browser_runtime.py", "tests/support/local_build.py",
                     "OMPGUI.entitlements", "OMPGUI.xcodeproj/project.pbxproj"):
            (self.repo / path).write_text("initial\n")
        library = self.repo / build_inputs.LIBRARY
        library.parent.mkdir(parents=True)
        library.write_bytes(b"fake dev binary")

    def script(self, name, source):
        path = f"tests/{name}.py"
        (self.repo / path).write_text(source)
        return Check(name, name, recipe="python", inputs=(path,))

    def execute(self, engine):
        with redirect_stdout(io.StringIO()):
            engine.execute()

    def test_failure_stops_later_checks_and_records_them(self):
        first = self.script("fail", "raise SystemExit(7)\n")
        second = self.script("later", "raise RuntimeError('must not execute')\n")
        engine = Engine(self.repo, [first, second])
        with self.assertRaises(CheckFailed) as error:
            self.execute(engine)
        self.assertEqual(error.exception.code, 7)
        report = json.loads((engine.run_root / "report.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual([item["status"] for item in report["checks"][:2]], ["failed", "not-run"])
        self.assertFalse(engine.outputs[second.id].exists())
        self.assertIn("SystemExit", (self.repo / first.inputs[0]).read_text())

    def test_all_prerequisites_checked_before_any_execution(self):
        first = self.script("first", "print('should not run')\n")
        absent = Check("absent", "needs missing input", recipe="python", inputs=("tests/absent.py",))
        engine = Engine(self.repo, [first, absent])
        with self.assertRaisesRegex(ValueError, "missing input"):
            self.execute(engine)
        self.assertFalse(engine.outputs[first.id].exists())
        self.assertEqual(engine.records[0]["status"], "not-run")

    def test_processes_use_literal_paths_and_isolated_profile(self):
        check = self.script("environment", "import json, os\nprint(json.dumps({k: os.environ.get(k) for k in "
                            "['PI_CONFIG_DIR', 'PI_CONFIG_FILES', 'OMP_PROFILE', 'OMP_PRIVATE_TOKEN', 'TMPDIR', 'XDG_STATE_HOME']}))\n")
        engine = Engine(self.repo, [check])
        with patch.dict(os.environ, {"PI_CONFIG_DIR": "/owner/profile", "PI_CONFIG_FILES": "/owner/settings", "OMP_PRIVATE_TOKEN": "secret", "XDG_STATE_HOME": "/owner/state"}):
            self.execute(engine)
        log = (engine.outputs[check.id] / "checks.log").read_text().splitlines()[-1]
        values = json.loads(log)
        self.assertFalse(Path(values["PI_CONFIG_DIR"]).is_absolute())
        self.assertEqual((Path.home() / values["PI_CONFIG_DIR"]).resolve(), engine.outputs[check.id] / "profile")
        self.assertIsNone(values["XDG_STATE_HOME"])
        self.assertIsNone(values["PI_CONFIG_FILES"])
        self.assertIsNone(values["OMP_PRIVATE_TOKEN"])
        self.assertEqual(values["OMP_PROFILE"], "default")
        self.assertEqual(values["TMPDIR"], str(engine.outputs[check.id] / "tmp"))

    def test_repeat_runs_use_fresh_directories_and_do_not_skip_results(self):
        check = self.script("ok", "print('passed')\n")
        first, second = Engine(self.repo, [check]), Engine(self.repo, [check])
        self.execute(first)
        self.execute(second)
        self.assertNotEqual(first.run_root, second.run_root)
        for engine in (first, second):
            report = json.loads((engine.run_root / "report.json").read_text())
            self.assertEqual(report["status"], "passed")
            self.assertIn("inputs_sha256", report["checks"][0])
            self.assertTrue(report["checks"][0]["commands"])

    def test_timeout_terminates_owned_child_processes(self):
        check = self.script("timeout", "import subprocess, sys, time\nfrom pathlib import Path\n"
                            "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])\n"
                            "Path('child.pid').write_text(str(child.pid))\ntime.sleep(30)\n")
        check = Check(check.area, check.description, recipe=check.recipe, inputs=check.inputs, timeout=0.5)
        engine = Engine(self.repo, [check])
        with self.assertRaises(CheckFailed) as error:
            self.execute(engine)
        self.assertEqual(error.exception.code, 124)
        child = (self.repo / "child.pid").read_text()
        state = subprocess.run(["ps", "-o", "stat=", "-p", child], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), f"Owned child still running: {state}")

    def test_native_requires_explicit_runtime(self):
        engine = Engine(self.repo, [Check("rpc", "native", tier="native", recipe="native-rpc")])
        with self.assertRaisesRegex(ValueError, "require --omp"):
            self.execute(engine)

    def test_relocated_question_results_use_the_worktree_sdk_host(self):
        responses = self.repo / "build.noindex/verification/runs/moved run/functional/questions"
        engine = Mock(repo=self.repo, outputs={"functional:questions": responses}, package_root=Path("/installed/omp"))
        run_recipe(engine, registry()["native:questions"], self.repo / "native-output")
        command = engine.command.call_args.args[0]
        self.assertEqual(command[2], responses)
        self.assertEqual(command[-1], self.repo / build_inputs.PRODUCTS /
                         "OMP GUI Dev.app/Contents/Resources/OMPSDKHost.js")

    def test_config_forwarder_accepts_new_run_layout_and_rejects_external_profile(self):
        original = RegistryTests.repo / "tests/fixtures/omp/config_cli.py"
        fixture = self.repo / "tests/fixtures/omp/config_cli.py"
        fixture.parent.mkdir(parents=True)
        fixture.write_text(original.read_text())
        fake = self.repo / "fake-omp"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n')
        fake.chmod(0o700)
        output = self.repo / "build.noindex/verification/runs/moved run/native/config"
        (output / "agent").mkdir(parents=True)
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("PI_", "OMP_"))}
        environment.update(OMP_P3_CONFIG_ROOT=str(output), PI_CODING_AGENT_DIR=str(output / "agent"),
                           OMP_P3_REAL_CLI=str(fake))
        result = subprocess.run([sys.executable, str(fixture), "config", "get"], env=environment,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "config get")
        self.assertEqual(json.loads((output / "calls.jsonl").read_text())["overlayPresent"], False)
        environment["PI_CODING_AGENT_DIR"] = str(self.repo / "owner-profile")
        rejected = subprocess.run([sys.executable, str(fixture), "config", "get"], env=environment,
                                  capture_output=True, text=True, timeout=5)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Refusing non-isolated", rejected.stderr)
        self.assertEqual(len((output / "calls.jsonl").read_text().splitlines()), 1)

    def test_benchmark_requires_paper_before_start(self):
        engine = Engine(self.repo, [Check("markdown-preview", "benchmark", tier="benchmark", recipe="benchmark-markdown")])
        with self.assertRaisesRegex(ValueError, "requires --paper"):
            self.execute(engine)

    def test_freshness_rejects_source_and_binary_changes(self):
        build_inputs.record(self.repo, build_inputs.source_digest(self.repo))
        self.assertEqual(build_inputs.verify(self.repo)["schema"], 1)
        source = self.repo / "OMPGUI/source.swift"
        source.write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "stale"):
            build_inputs.verify(self.repo)
        source.write_text("initial\n")
        build_inputs.verify(self.repo)
        (self.repo / build_inputs.LIBRARY).write_bytes(b"wrong binary")
        with self.assertRaisesRegex(ValueError, "stale"):
            build_inputs.verify(self.repo)

    def test_tooling_and_docs_do_not_invalidate_app_evidence(self):
        build_inputs.record(self.repo, build_inputs.source_digest(self.repo))
        (self.repo / "tests/run.py").write_text("new tooling\n")
        (self.repo / "README.md").write_text("new docs\n")
        build_inputs.verify(self.repo)

    def test_concurrent_source_change_cannot_certify_build(self):
        before = build_inputs.source_digest(self.repo)
        (self.repo / "OMPGUI/source.swift").write_text("changed during build\n")
        with self.assertRaisesRegex(ValueError, "during build"):
            build_inputs.record(self.repo, before)
        self.assertFalse((self.repo / build_inputs.RECORD).exists())

    def test_compilation_reuses_identical_content_but_not_stale_content(self):
        source = self.repo / "OMPGUI/source.swift"
        check = Check("compiled", "compile", sources=("OMPGUI/source.swift",))
        engine = Engine(self.repo, [check])
        engine.tools["xcrun"] = "/fake/xcrun"
        compilations = []

        def compiler(command, **_kwargs):
            if "--version" in command:
                return "Fake Swift 6\n"
            compilations.append(command)
            Path(command[-1]).write_bytes(b"compiled")
            return ""

        with patch.object(engine, "command", side_effect=compiler), redirect_stdout(io.StringIO()):
            engine.compile(check)
            engine.compile(check)
            self.assertEqual(len(compilations), 1)
            stat = source.stat()
            source.write_text("changed\n")
            os.utime(source, ns=(stat.st_atime_ns, stat.st_mtime_ns))
            executable = engine.compile(check)
            self.assertEqual(len(compilations), 2)
            executable.write_bytes(b"replaced cached helper")
            engine.compile(check)
        self.assertEqual(len(compilations), 3)


if __name__ == "__main__":
    unittest.main()
