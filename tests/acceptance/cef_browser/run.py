#!/usr/bin/env python3
"""Explicitly authorized, local CEF/OMP GUI acceptance; never a routine check."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from urllib.parse import urlparse, parse_qs
from capability_fixture import capability_page, frame_page
from repair_fixture import repair_page, repair_frame

REPO = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / "tests/support"))
from cef_dependency_patches import prepare_cef, prepare_omp, digest
from local_build import clear_generated_quarantine, swiftpm_environment

PIN = "ba6ebff9e232529289662a84704ade1240563031"


def build_inputs():
    paths = [SOURCE / "Package.swift", *sorted((SOURCE / "Sources").glob("*.swift")),
             SOURCE / "patches/cefswift-cdp-dialogs.patch", SOURCE / "patches/sources.json"]
    return {str(path.relative_to(SOURCE)): digest(path) for path in paths}


def wait_for(read, predicate, seconds=25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = read()
            if predicate(value):
                return value
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise TimeoutError("Acceptance condition did not complete")


def build(root):
    executable = str(root / "products/OMPGUICefPrototype.app/Contents/MacOS/OMPGUICefPrototype")
    for state_file in root.glob("runs/*/native-state.json"):
        try:
            pid = json.loads(state_file.read_text())["pid"]
            command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
            if executable in command:
                raise RuntimeError("This prototype build is running; finish that acceptance instance before rebuilding.")
        except (OSError, ValueError, KeyError):
            pass
    _, cef_patch = prepare_cef(root, SOURCE / "patches")
    package = root / "package"
    package.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE / "Package.swift", package)
    shutil.copytree(SOURCE / "Sources", package / "Sources", dirs_exist_ok=True)
    # All package downloads, framework conversion and binaries stay in build.noindex.
    cache = package / ".cef/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    for archive in root.glob("cef_binary_*_macosarm64_minimal.tar.bz2"):
        destination = cache / archive.name
        if not destination.exists():
            shutil.copy2(archive, destination)
    command = ["swift", "package", "--package-path", str(package), "--disable-sandbox",
               "--allow-writing-to-package-directory", "--allow-network-connections", "all",
               "cef", "bundle", "--product", "OMPGUICefPrototype", "--configuration", "debug",
               "--output", str(root / "products"), "--bundle-id", "dev.ompgui.mac.dev.cef-prototype", "--sign", "-"]
    with (root / "build.log").open("w") as log:
        subprocess.run(command, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=True,
                       env=dict(os.environ, **swiftpm_environment(REPO, root / "tmp")))
    app = root / "products/OMPGUICefPrototype.app"
    catalog = json.loads((REPO / "OMPGUI/Resources/Localizable.xcstrings").read_text())["strings"]
    # Generate the prototype's bundle strings from the single production catalog.
    for language in ["en", "zh-Hans"]:
        folder = app / "Contents/Resources" / (language + ".lproj")
        folder.mkdir(parents=True, exist_ok=True)
        strings = {key: value.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", key)
                   for key, value in catalog.items()}
        (folder / "Localizable.strings").write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    clear_generated_quarantine(REPO, app)
    (root / "build-dependencies.json").write_text(json.dumps({"inputs": build_inputs(), "cefPatch": cef_patch}, indent=2))
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--omp", required=True, type=Path)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--keep-open", action="store_true")
    parser.add_argument("--case", choices=["all", "closing", "cancellation", "capabilities", "repairs"], default="all")
    parser.add_argument("--groups", default="", help="Comma-separated capability groups; default selects the documented matrix")
    args = parser.parse_args()
    root = REPO / "build.noindex/cef-prototype"
    root.mkdir(parents=True, exist_ok=True)
    app = root / "products/OMPGUICefPrototype.app" if args.skip_build else build(root)
    if args.skip_build:
        metadata = root / "build-dependencies.json"
        if not metadata.exists() or json.loads(metadata.read_text())["inputs"] != build_inputs():
            raise RuntimeError("Prototype inputs changed; build once before --skip-build")
    if args.build_only:
        print(app, flush=True)
        return
    installed_package = args.omp.resolve().parent.parent
    package_root, omp_patch = prepare_omp(root, installed_package, SOURCE / "patches")
    if args.case == "repairs":
        probe = root / "image-probe"
        signature = root / "image-probe.sha256"
        source_hash = digest(SOURCE / "image_probe.swift")
        if not probe.exists() or not signature.exists() or signature.read_text() != source_hash:
            subprocess.run(["xcrun", "swiftc", str(SOURCE / "image_probe.swift"), "-o", str(probe)], check=True)
            signature.write_text(source_hash)
        clear_generated_quarantine(REPO, probe)
    run = root / "runs" / uuid.uuid4().hex
    run.mkdir(parents=True)
    os.chmod(run, 0o700)
    proofs = []
    command_lock = threading.Lock()
    catalog = json.loads((REPO / "OMPGUI/Resources/Localizable.xcstrings").read_text())["strings"]
    labels = {key: catalog[key]["localizations"]["zh-Hans"]["stringUnit"]["value"]
              for key in ["Name", "Apply", "Output", "Native instance"]}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, value, code=200):
            data = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def page(self, html):
            data = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/native-state":
                self.reply(json.loads((run / "native-state.json").read_text()))
            elif path == "/proof":
                self.reply(proofs)
            elif path == "/capabilities":
                self.page(capability_page(base, cross_base, labels))
            elif path == "/frame":
                self.page(frame_page(labels))
            elif path == "/repair":
                self.page(repair_page(base, cross_base))
            elif path == "/repair-frame":
                self.page(repair_frame(parse_qs(urlparse(self.path).query).get("kind", ["same"])[0], cross_base))
            elif path.startswith("/api/"):
                self.reply({"fixture": "CEF", "path": self.path, "header": self.headers.get("X-CEF-Test")})
            elif path == "/download":
                data = b"OMP CEF download fixture\n"
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", 'attachment; filename="cef-download.txt"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif path == "/fixture":
                html = """<!doctype html><meta charset="utf-8"><style>
body{font:20px system-ui;padding:36px;background:#edf4ff;color:#12254a}input,textarea,button{font:inherit;padding:10px;margin:8px 0}input,textarea{display:block;width:80%}#native{font-size:14px;overflow-wrap:anywhere}#output{padding:20px;background:white;border:2px solid #2456b2;min-height:40px}h1{color:#2456b2}</style>
<h1 id="heading"></h1><p>__NATIVE__</p><p id="native"></p>
<label>__NAME__<input id="name" autocomplete="off"></label><textarea id="notes"></textarea>
<button id="apply">__APPLY__</button><p>__OUTPUT__</p><div id="output"></div>
<script>
const query=new URL(location.href).searchParams;window.instance=query.get('instance');window.tab=query.get('tab');
document.title='OMP CEF '+tab+' '+instance;document.querySelector('#heading').textContent='OMP CEF '+tab;
window.inputEvents=[];for(const kind of ['keydown','input','click'])document.addEventListener(kind,e=>inputEvents.push({kind,trusted:e.isTrusted,target:e.target.id}));
document.querySelector('#apply').onclick=()=>{document.querySelector('#output').textContent=document.querySelector('#name').value};
console.log('fixture-ready');
</script>"""
                for key, token in [("Native instance", "NATIVE"), ("Name", "NAME"), ("Apply", "APPLY"), ("Output", "OUTPUT")]:
                    html = html.replace("__" + token + "__", labels[key])
                data = html.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self.reply({}, 404)

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 65536:
                self.reply({}, 400)
                return
            raw = self.rfile.read(size)
            if self.path == "/api/upload":
                self.reply({"bytes": len(raw), "contents": raw.decode()})
                return
            body = json.loads(raw)
            if self.path == "/native-proof":
                proofs.append(body)
                with (run / "native-proofs.jsonl").open("a") as log:
                    log.write(json.dumps(body, ensure_ascii=False) + "\n")
                self.reply({"ok": True})
            elif self.path == "/control":
                with command_lock:
                    body["id"] = uuid.uuid4().hex
                    temporary = run / "command.tmp"
                    temporary.write_text(json.dumps(body))
                    temporary.replace(run / "command.json")
                    state = wait_for(lambda: json.loads((run / "native-state.json").read_text()),
                                     lambda value: value["lastCommand"] == body["id"])
                    with (run / "native-controls.jsonl").open("a") as log:
                        log.write(json.dumps({"command": body, "state": state}) + "\n")
                    self.reply(state)
            else:
                self.reply({}, 404)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    cross_server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=cross_server.serve_forever, daemon=True).start()
    cross_base = f"http://localhost:{cross_server.server_port}"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        cdp_port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{server.server_port}"
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("OMP_", "PI_", "CEF_")) and key not in ["HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]}
    home = run / "home"
    home.mkdir()
    env.update(HOME=str(home), PI_CONFIG_DIR=str(run / "config"), PI_CODING_AGENT_DIR=str(run / "agent"),
               CEF_PROTOTYPE_RUN=str(run), CEF_PROTOTYPE_CDP_PORT=str(cdp_port),
               CEF_PROTOTYPE_FIXTURE_URL=base, MallocNanoZone="0")
    env["CEF_PROTOTYPE_CASE"] = args.case
    env["CEF_PROTOTYPE_GROUPS"] = args.groups
    (run / "environment.json").write_text(json.dumps({"cdpURL": f"http://127.0.0.1:{cdp_port}", "fixtureURL": base,
        "cefSwiftRevision": PIN, "ompExecutable": str(args.omp.resolve()), "ompPackageRoot": str(package_root),
        "dependencyPatches": {"omp": omp_patch, "cef": json.loads((root / "build-dependencies.json").read_text())["cefPatch"]}}, indent=2))
    print("RUN=" + str(run), flush=True)
    with (run / "app.log").open("w") as log:
        process = subprocess.Popen([str(app / "Contents/MacOS/OMPGUICefPrototype"), "-AppleLanguages", "(zh-Hans)"],
                                   env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            state = wait_for(lambda: json.loads((run / "native-state.json").read_text()),
                             lambda value: len(value["tabs"]) == 2 and all(tab["bound"] for tab in value["tabs"]), seconds=40)
            (run / "initial-native-state.json").write_text(json.dumps(state, indent=2))
            with (run / "omp.log").open("w") as omp_log:
                script = {"capabilities": "capability_tests.mjs", "repairs": "frame_dialog_tests.mjs"}.get(args.case, "browser_tests.mjs")
                try:
                    subprocess.run(["bun", str(SOURCE / script), str(run), str(package_root), base],
                                   cwd=run, env=env, stdout=omp_log, stderr=subprocess.STDOUT, check=True, timeout=240)
                except subprocess.CalledProcessError:
                    if args.keep_open:
                        print("Acceptance failed; prototype retained for diagnosis. Interrupt this driver to finish.", flush=True)
                        try:
                            process.wait()
                        except KeyboardInterrupt:
                            pass
                    raise
            result = json.loads((run / "result.json").read_text())
            if args.keep_open:
                print(json.dumps({"measurementStatus": result["status"], "hostStatus": "running",
                                  "checks": len(result["checks"]), "phase": args.case, "run": str(run)}, ensure_ascii=False), flush=True)
                print("Prototype remains open; interrupt this driver after inspection.", flush=True)
                try:
                    process.wait()
                except KeyboardInterrupt:
                    pass
        finally:
            had_error = sys.exc_info()[0] is not None
            forced = False
            if process.poll() is None:
                (run / "command.json").write_text(json.dumps({"id": uuid.uuid4().hex, "action": "quit"}))
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    forced = True
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        # A native modal dialog can block both the control timer
                        # and graceful SIGTERM. Only kill this owned fixture host.
                        process.kill()
                        process.wait(timeout=5)
            server.shutdown()
            cross_server.shutdown()
            shutdown = {"exitCode": process.returncode, "forcedTermination": forced}
            (run / "shutdown.json").write_text(json.dumps(shutdown, indent=2))
            result_file = run / "result.json"
            if result_file.exists():
                result = json.loads(result_file.read_text())
                result["hostShutdown"] = shutdown
                if process.returncode != 0 or forced:
                    result["status"] = "failed"
                    result["shutdownError"] = "The owned CEF host did not exit cleanly"
                result_file.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
                print(json.dumps({"status": result["status"], "checks": len(result.get("checks", [])),
                                  "phase": args.case, "run": str(run), "hostShutdown": shutdown}, ensure_ascii=False), flush=True)
            if (process.returncode != 0 or forced) and not had_error:
                raise RuntimeError("CEF acceptance host shutdown failed; inspect shutdown.json")


if __name__ == "__main__":
    main()
