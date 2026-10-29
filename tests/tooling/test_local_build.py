"""Local build metadata boundaries; never execute a quarantined artifact."""
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest

from support.local_build import clear_generated_quarantine, compile_swift, swiftpm_environment


@unittest.skipUnless(sys.platform == "darwin", "macOS quarantine metadata")
class LocalBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="local build spaces ")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name).resolve()
        self.generated = self.repo / "build.noindex/checks"
        self.generated.parent.mkdir()
        self.generated.write_bytes(b"locally compiled result")
        self.marker = b"0081;00000000;OMP GUI Dev;"
        self.set_attribute(self.generated, "com.apple.quarantine", self.marker)

    def set_attribute(self, path, name, value):
        subprocess.run(["/usr/bin/xattr", "-w", name, value.decode(), str(path)], check=True, capture_output=True)

    def attribute(self, path, name):
        return subprocess.check_output(["/usr/bin/xattr", "-p", name, str(path)]).rstrip(b"\n")

    def test_only_generated_target_loses_quarantine(self):
        neighbour = self.generated.with_name("unselected")
        neighbour.write_bytes(b"not selected")
        self.set_attribute(neighbour, "com.apple.quarantine", self.marker)
        self.set_attribute(self.generated, "com.ompgui.verification", b"keep")
        clear_generated_quarantine(self.repo, self.generated)
        self.assertNotIn("com.apple.quarantine", subprocess.check_output(["/usr/bin/xattr", str(self.generated)], text=True).splitlines())
        self.assertEqual(self.attribute(self.generated, "com.ompgui.verification"), b"keep")
        self.assertEqual(self.generated.read_bytes(), b"locally compiled result")
        self.assertEqual(self.attribute(neighbour, "com.apple.quarantine"), self.marker)

    def test_external_file_and_escaping_symlink_remain_quarantined(self):
        external = self.repo / "downloaded"
        external.write_bytes(b"external input")
        self.set_attribute(external, "com.apple.quarantine", self.marker)
        link = self.generated.with_name("escape")
        link.symlink_to(external)
        for path in (external, link, self.generated.parent):
            with self.subTest(path=path), self.assertRaises(ValueError):
                clear_generated_quarantine(self.repo, path)
        self.assertEqual(self.attribute(external, "com.apple.quarantine"), self.marker)
        self.assertEqual(self.attribute(self.generated, "com.apple.quarantine"), self.marker)

    def test_failed_compilation_does_not_approve_stale_output(self):
        code = compile_swift(self.repo, "/usr/bin/false", ["-o", str(self.generated)])
        self.assertEqual(code, 1)
        self.assertEqual(self.attribute(self.generated, "com.apple.quarantine"), self.marker)

    def test_compiler_and_temporary_outputs_cannot_escape_build_root(self):
        external = self.repo / "outside"
        for operation in (
            lambda: compile_swift(self.repo, "/usr/bin/true", ["-o", str(external)]),
            lambda: swiftpm_environment(self.repo, external),
        ):
            with self.assertRaises(ValueError):
                operation()
        self.assertFalse(external.exists())


if __name__ == "__main__":
    unittest.main()
