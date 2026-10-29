"""Validate repository Markdown links, anchors and navigation without network access."""
from pathlib import Path
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlsplit


FENCE = re.compile(r"^\s{0,3}(" + chr(96) + r"{3,}|~{3,})")
INLINE_CODE = re.compile(r"(" + chr(96) + r"+).*?\1")
LINK = re.compile(r"!?\[[^\]\n]*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+['\"].*?['\"])?\s*\)")
DEFINITION = re.compile(r"^\s{0,3}\[([^\]]+)\]:\s*(?:<([^>\n]+)>|(\S+))", re.M)
REFERENCE = re.compile(r"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]")
IMAGE_REFERENCE = re.compile(r"!\[([^\]\n]*)\]\[([^\]\n]+)\]")


def prose(text):
    """Hide examples, preserving line numbers and headings outside fences."""
    lines = text.splitlines()
    frontmatter = bool(lines and lines[0] == "---")
    fence = None
    for index, line in enumerate(lines):
        if frontmatter:
            if index > 0 and line == "---":
                frontmatter = False
            lines[index] = ""
            continue
        match = FENCE.match(line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= len(fence):
                fence = None
            lines[index] = ""
        elif match:
            fence = match[1]
            lines[index] = ""
    return "\n".join(lines)


def anchors(text):
    body = prose(text)
    headings = []
    lines = body.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
        if match:
            headings.append(match[1])
        elif index and re.fullmatch(r"\s{0,3}(?:=+|-+)\s*", line) and lines[index - 1].strip():
            headings.append(lines[index - 1].strip())
    found = set(re.findall(r'<a\s+(?:id|name)=["\']([^"\']+)["\']', body, re.I))
    for heading in headings:
        heading = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", heading)
        heading = re.sub(r"<[^>]+>", "", heading).lower()
        slug = "".join(char for char in heading
                       if char in "_- " or unicodedata.category(char)[0] in "LN")
        slug = slug.replace(" ", "-")
        candidate = slug
        suffix = 0
        while candidate in found:
            suffix += 1
            candidate = f"{slug}-{suffix}"
        found.add(candidate)
    return found


def links(text):
    body = INLINE_CODE.sub("", prose(text))
    definitions = {match[1].casefold(): match[2] or match[3] for match in DEFINITION.finditer(body)}
    result = [(match.start(), match[1] or match[2]) for match in LINK.finditer(body)]
    for pattern in (REFERENCE, IMAGE_REFERENCE):
        for match in pattern.finditer(body):
            key = (match[2] or match[1]).casefold()
            if key in definitions:
                result.append((match.start(), definitions[key]))
    # Definitions also need validation when currently unused.
    result.extend((match.start(), match[2] or match[3]) for match in DEFINITION.finditer(body))
    return [(body.count("\n", 0, offset) + 1, destination) for offset, destination in result]


def validate(repo, documents):
    repo = repo.resolve()
    documents = set(documents)
    texts = {path: (repo / path).read_text(encoding="utf-8") for path in documents}
    targets = {path: anchors(text) for path, text in texts.items()}
    graph = {path: set() for path in documents}
    errors = []
    count = 0
    for path in sorted(documents):
        for line, destination in links(texts[path]):
            parsed = urlsplit(destination)
            if parsed.scheme or parsed.netloc:
                continue
            count += 1
            target = (repo / path.parent / unquote(parsed.path)).resolve() if parsed.path else repo / path
            try:
                relative = target.relative_to(repo)
            except ValueError:
                errors.append(f"{path}:{line}: link leaves repository: {destination}")
                continue
            if not target.exists():
                errors.append(f"{path}:{line}: missing local target: {destination}")
                continue
            if target.is_dir() and (target / "README.md").is_file():
                relative /= "README.md"
            if relative in documents:
                graph[path].add(relative)
                fragment = unquote(parsed.fragment)
                if fragment and fragment not in targets[relative]:
                    errors.append(f"{path}:{line}: missing heading #{fragment} in {relative}")
    reached = set()
    pending = [Path("README.md")]
    while pending:
        path = pending.pop()
        if path in reached or path not in graph:
            continue
        reached.add(path)
        pending.extend(graph[path] - reached)
    errors.extend(f"{path}: unreachable from README.md; link it from the documentation index"
                  for path in sorted(documents - reached))
    return errors, count


def main():
    repo = Path(__file__).resolve().parents[2]
    inventory = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*.md"],
        cwd=repo,
    ).decode("utf-8").split("\0")
    documents = {Path(name) for name in inventory if name and (repo / name).is_file()}
    errors, count = validate(repo, documents)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Documentation passed: {len(documents)} Markdown files, {count} local links; all reachable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
