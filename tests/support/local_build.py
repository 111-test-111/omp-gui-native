"""Prepare only this worktree's locally generated code for execution on macOS.

GUI-launched tools inherit automatic quarantine attribution. Downloaded inputs,
installed applications and system security policy are never modified here.
"""
import argparse
import ctypes
import errno
from itertools import chain
import os
from pathlib import Path
import shlex
import subprocess
import sys


def scoped_path(repo, path):
    root = Path(repo).resolve() / "build.noindex"
    target = Path(path).resolve()
    if target == root or not target.is_relative_to(root):
        raise ValueError(f"Refusing non-generated path outside this worktree's build.noindex: {path}")
    return target


def clear_generated_quarantine(repo, path):
    target = scoped_path(repo, path)
    if sys.platform != "darwin":
        return
    # Python's os.*xattr APIs are Linux-only; use macOS's no-follow syscall.
    remove = ctypes.CDLL(None, use_errno=True).removexattr
    remove.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
    remove.restype = ctypes.c_int
    entries = chain((target,), target.rglob("*") if target.is_dir() else ())
    for entry in entries:
        if entry.is_symlink():
            continue
        scoped_path(repo, entry)
        if remove(os.fsencode(entry), b"com.apple.quarantine", 1) != 0:  # XATTR_NOFOLLOW
            error = ctypes.get_errno()
            if error not in {errno.ENODATA, errno.ENOATTR}:
                raise OSError(error, os.strerror(error), str(entry))


def compile_swift(repo, compiler, arguments):
    output = None
    if "-o" in arguments:
        output = scoped_path(repo, arguments[arguments.index("-o") + 1])
    result = subprocess.run([str(compiler), *arguments])
    if result.returncode == 0 and output is not None:
        clear_generated_quarantine(repo, output)
    return result.returncode


def swiftpm_environment(repo, temporary):
    if sys.platform != "darwin":
        return {}
    temporary = scoped_path(repo, temporary)
    temporary.mkdir(parents=True, exist_ok=True)
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    wrapper = scoped_path(repo, Path(repo) / "build.noindex/tools/swiftc")
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, str(Path(__file__).resolve()), "compiler", str(Path(repo).resolve()), compiler, "--"]
    source = "#!/bin/sh\nexec " + shlex.join(command) + ' "$@"\n'
    if not wrapper.exists() or wrapper.read_text() != source:
        wrapper.write_text(source)
    wrapper.chmod(0o700)
    clear_generated_quarantine(repo, wrapper)
    return {"SWIFT_EXEC": str(wrapper), "SWIFT_EXEC_MANIFEST": str(wrapper), "TMPDIR": str(temporary)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    compiler = modes.add_parser("compiler")
    compiler.add_argument("repo", type=Path)
    compiler.add_argument("swiftc", type=Path)
    compiler.add_argument("arguments", nargs=argparse.REMAINDER)
    run = modes.add_parser("run")
    run.add_argument("--product", type=Path)
    run.add_argument("repo", type=Path)
    run.add_argument("temporary", type=Path)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if args.mode == "compiler":
        return compile_swift(args.repo, args.swiftc, arguments)
    if args.product is not None:
        scoped_path(args.repo, args.product)
    environment = dict(os.environ, **swiftpm_environment(args.repo, args.temporary))
    result = subprocess.run(arguments, env=environment)
    if result.returncode == 0 and args.product is not None:
        clear_generated_quarantine(args.repo, args.product)
    return result.returncode


if __name__ == "__main__":
    try:
        code = main()
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        code = 2
    raise SystemExit(code if code >= 0 else 128 - code)
