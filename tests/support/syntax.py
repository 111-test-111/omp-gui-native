"""Syntax-only tooling validation. Does not import fixtures or run test workloads."""
import ast
from collections import Counter
from pathlib import Path
import subprocess


def main():
    repo = Path(__file__).resolve().parents[2]
    counts = Counter()
    for directory in (repo / "tests", repo / "scripts"):
        for path in sorted(directory.rglob("*")):
            if not path.is_file() or any(part in {"node_modules", "__pycache__"} for part in path.parts):
                continue
            extension = path.suffix
            if extension == ".py":
                ast.parse(path.read_text(), filename=str(path))
            elif extension == ".sh":
                subprocess.run(["bash", "-n", str(path)], check=True)
            elif extension in {".js", ".mjs"}:
                subprocess.run(["node", "--check", str(path)], check=True)
            elif extension == ".swift":
                subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", str(path)], check=True)
            else:
                continue
            counts[extension] += 1
    print("Syntax passed: " + ", ".join(f"{extension}={count}" for extension, count in sorted(counts.items())))


if __name__ == "__main__":
    main()
