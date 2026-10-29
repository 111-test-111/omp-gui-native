"""Behavior checks for the static documentation validator; temporary files only."""
from pathlib import Path
import tempfile
import unittest

from documentation_tests import validate


class DocumentationTests(unittest.TestCase):
    def check(self, files):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for name, content in files.items():
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            documents = {Path(name) for name in files if name.endswith(".md")}
            return validate(repo, documents)

    def test_valid_relative_links_images_references_and_escaped_names(self):
        errors, count = self.check({
            "README.md": "# Start\n[Guide](guide.md#目标)\n[Image][asset]\n[asset]: <a b.png>\n",
            "guide.md": "# 目标\n[Home](README.md)\n![asset](a%20b.png)\n[Remote](https://example.invalid/missing)\n",
            "a b.png": "",
        })
        self.assertEqual(errors, [])
        self.assertEqual(count, 5)

    def test_missing_file_and_heading_are_reported(self):
        errors, _ = self.check({
            "README.md": "# Home\n[missing](gone.md)\n[heading](guide.md#gone)\n",
            "guide.md": "# Present\n",
        })
        self.assertTrue(any("missing local target" in error for error in errors))
        self.assertTrue(any("missing heading #gone" in error for error in errors))

    def test_code_examples_are_not_links(self):
        tick = chr(96)
        errors, count = self.check({
            "README.md": f"# Home\n{tick}[example](missing.md){tick}\n{tick * 3}md\n[example](gone.md)\n{tick * 3}\n",
        })
        self.assertEqual(errors, [])
        self.assertEqual(count, 0)

    def test_unicode_duplicate_and_setext_heading_fragments(self):
        errors, _ = self.check({
            "README.md": "[a](guide.md#中文标题)\n[b](guide.md#中文标题-1)\n[c](guide.md#setext)\n",
            "guide.md": "# 中文标题\n# 中文标题\nSetext\n======\n[self](#setext)\n",
        })
        self.assertEqual(errors, [])

    def test_orphan_and_repository_escape_are_rejected(self):
        errors, _ = self.check({
            "README.md": "# Home\n[outside](../outside.md)\n",
            "orphan.md": "# Orphan\n",
        })
        self.assertTrue(any("leaves repository" in error for error in errors))
        self.assertTrue(any("orphan.md: unreachable" in error for error in errors))
