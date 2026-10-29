#!/usr/bin/env python3
"""Prepare the production browser regression host; --run requires owner authorization."""
import argparse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import threading
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from catalog import Check
from support.engine import Engine


class LoginFixture(BaseHTTPRequestHandler):
    """Real HTTP login with HttpOnly persistent and session cookies."""
    def log_message(self, *args):
        pass

    def reply(self, body, content_type="text/html", cookies=()):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        for cookie in cookies:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        if self.path == "/session":
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            persistent = cookies.get("omp_persistent")
            session = cookies.get("omp_session")
            account = persistent.value if persistent else ""
            self.reply(json.dumps({"authenticated": bool(account and session and session.value == account),
                                   "account": account, "session": session.value if session else ""}),
                       "application/json")
            return
        self.reply('''<!doctype html><meta charset="utf-8"><title>OMP profile login fixture</title>
<h1>Browser profile login</h1><form method="post" action="/login" id="login">
<input name="account" id="account"><button type="submit">Sign in</button></form>''')

    def do_POST(self):
        account = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()).get("account", [""])[0]
        if self.path != "/login" or account not in ("account-a", "account-b"):
            self.send_error(400)
            return
        self.reply('<!doctype html><title>Signed in</title><h1 id="signed-in">Signed in</h1>', cookies=(
            f"omp_persistent={account}; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax",
            f"omp_session={account}; Path=/; HttpOnly; SameSite=Lax"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Launch and quit only this isolated acceptance host, after owner consent")
    parser.add_argument("--presentation", action="store_true", help="Keep one visible panel available for menu/tab inspection, then validate blank-page stability")
    parser.add_argument("--profiles", action="store_true", help="Verify real HTTP login, shared storage, pending switches and profile persistence across five processes")
    parser.add_argument("--profile-settings", action="store_true", help="Keep the isolated production Browser settings visible for UI inspection")
    parser.add_argument("--automation", action="store_true", help="Verify native Browser/Eval against two production tabs, hidden views, state and recovery")
    parser.add_argument("--omp", help="Explicit installed OMP npm executable for --automation --run")
    parser.add_argument("--automation-from", choices=("start", "state", "frames", "recovery", "options", "downloads", "tls"), default="start",
                        help="Resume only the remaining acceptance phases after fixing their implementation or fixture")
    args = parser.parse_args()
    if sum((args.profiles, args.profile_settings, args.presentation, args.automation)) > 1:
        parser.error("Select one acceptance scope")
    if args.automation and args.run and not args.omp:
        parser.error("--automation --run requires --omp /absolute/path/to/omp")
    check = Check("browser-acceptance", "Manual browser lifecycle", sources=("tests/acceptance/workspace_browser.swift",), app=True)
    engine = Engine(ROOT, (check,))
    engine.preflight()
    engine.current = {"id": check.id, "timeout_seconds": 120}
    engine.outputs[check.id].mkdir(parents=True)
    (engine.outputs[check.id] / "tmp").mkdir()
    executable = engine.compile(check)
    output = ROOT / "build.noindex/browser-acceptance" / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    app = output / "OMP GUI Browser Acceptance.app"
    code = app / "Contents/MacOS"
    code.mkdir(parents=True)
    (output / "storage").mkdir()
    product = ROOT / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents"
    info = plistlib.loads((product / "Info.plist").read_bytes())
    original_id = info["CFBundleIdentifier"]
    info["CFBundleIdentifier"] = original_id + ".browser-acceptance"
    info["CFBundleName"] = "OMP GUI Browser Acceptance"
    info["CFBundleDisplayName"] = info["CFBundleName"]
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    import shutil
    binary = code / info["CFBundleExecutable"]
    shutil.copy2(executable, binary)
    for item in (product / "MacOS").iterdir():
        if item.name != binary.name:
            (code / item.name).symlink_to(item)
    # The Chromium sandbox permits the containing bundle, not external symlink
    # targets. APFS-clone the complete nested code layout without changing it.
    subprocess.run(["/bin/cp", "-cR", str(product / "Frameworks"), str(app / "Contents/Frameworks")], check=True)
    # Give this test its own activation identity, and keep the helper rendezvous
    # prefix consistent with it. Only the cloned, unsigned acceptance app changes.
    for helper_info in (app / "Contents/Frameworks").glob("*.app/Contents/Info.plist"):
        helper = plistlib.loads(helper_info.read_bytes())
        helper["CFBundleIdentifier"] = helper["CFBundleIdentifier"].replace(original_id, info["CFBundleIdentifier"], 1)
        helper_info.write_bytes(plistlib.dumps(helper))
    (app / "Contents/Resources").symlink_to(product / "Resources")
    print(f"Prepared isolated browser acceptance: {app}", flush=True)
    if not args.run:
        return
    env = {key: value for key, value in os.environ.items() if not key.startswith(("OMP_", "PI_", "CEF_"))}
    env["MallocNanoZone"] = "0"
    if args.automation:
        from browser_automation import run_automation
        run_automation(ROOT, output, binary, env, args.omp, args.automation_from)
        return
    server = ThreadingHTTPServer(("127.0.0.1", 0), LoginFixture) if args.profiles else None
    if server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    phases = ("first", "persisted", "blank", "restored", "blank-restored") if args.profiles else (("first",) if args.presentation or args.profile_settings else ("first", "restart"))
    try:
        for phase in phases:
            command = [str(binary), "--website-captures", str(output)]
            if args.profiles:
                command += ["--profile-phase", phase, "--fixture-url", f"http://127.0.0.1:{server.server_port}"]
            if args.profile_settings:
                command += ["--profile-settings", "-AppleLanguages", "(zh-Hans)"]
            if args.presentation:
                command += ["--presentation", "-AppleLanguages", "(zh-Hans)"]
            if phase == "restart":
                command.append("--restart")
            with (output / (phase + ".log")).open("w") as log:
                subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    finally:
        if server:
            server.shutdown()
            server.server_close()
    print(f"Passed {', '.join(phases)}: {output}")


if __name__ == "__main__":
    main()
