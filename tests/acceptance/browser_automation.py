"""Deterministic local fixtures and explicit-run production browser automation acceptance."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import json
import ssl
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlsplit


class AutomationFixture(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        filename = None
        if url.path == "/download":
            name = parse_qs(url.query).get("name", ["fixture"])[0]
            if not name.replace("-", "").isalnum():
                self.send_error(400)
                return
            filename = name + ".txt"
            value = parse_qs(url.query).get("value", [name])[0]
            body = f"OMP acceptance {value} 中文✓\n"
        elif url.path == "/tls":
            body = '<!doctype html><title>TLS fixture</title><h1 id="tls-proof">Isolated certificate fixture</h1>'
        elif url.path == "/frame":
            body = '<!doctype html><meta charset="utf-8"><title>Child frame</title><input id="frame-name" value="child-value">'
        else:
            body = '''<!doctype html><meta charset="utf-8"><title>Identical automation fixture</title>
<style>body{font:18px system-ui}input,button{font:inherit;margin:10px;padding:10px}
#drag,#drop{width:120px;height:65px;display:inline-block;margin:20px;background:#bdf}
#drop{background:#fdc}#bottom{margin-top:1400px}iframe{display:block;width:600px;height:100px}</style>
<input id="name"><button id="apply">Apply</button><output id="output"></output>
<button id="confirm">Confirm</button><div id="drag">Drag</div><div id="drop">Drop</div>
<a id="download" href="/download?name=fixture">Download</a>
<iframe id="child" src="http://localhost:PORT/frame"></iframe><div id="bottom">Bottom</div>
<script>
window.trustedEvents=0;window.dropped=false;
document.addEventListener('input',e=>{if(e.isTrusted)trustedEvents++});
document.querySelector('#apply').onclick=e=>{if(e.isTrusted)trustedEvents++;document.querySelector('#output').textContent=document.querySelector('#name').value};
document.querySelector('#confirm').onclick=()=>window.confirmResult=confirm('Recovery fixture');
let dragging=false;document.querySelector('#drag').onpointerdown=e=>{dragging=e.isTrusted};
window.addEventListener('pointerup',e=>{const r=document.querySelector('#drop').getBoundingClientRect();window.dropped=dragging&&e.isTrusted&&e.clientX>=r.left&&e.clientX<=r.right&&e.clientY>=r.top&&e.clientY<=r.bottom;dragging=false});
</script>'''.replace("PORT", str(self.server.server_port))
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8" if filename else "text/html; charset=utf-8")
        if filename:
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class TLSFixtureServer(ThreadingHTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(4)
        # Chrome may preconnect without starting TLS. Handshake in the request
        # thread so one speculative socket cannot block the server's accept loop.
        return self.context.wrap_socket(connection, server_side=True, do_handshake_on_connect=False), address


def run_automation(repo, output, binary, environment, omp, start_at="start"):
    """Only called behind workspace_browser.py --automation --run."""
    package = Path(omp).expanduser().resolve().parent.parent
    if not (package / "src/index.ts").is_file():
        raise ValueError("--omp must select an installed native OMP npm SDK")
    server = ThreadingHTTPServer(("127.0.0.1", 0), AutomationFixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    tls = None
    if start_at == "tls":
        key, cert = output / "fixture.key", output / "fixture.crt"
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=127.0.0.1", "-keyout", str(key), "-out", str(cert)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)
        tls = TLSFixtureServer(("127.0.0.1", 0), AutomationFixture)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls.context = context
        threading.Thread(target=tls.serve_forever, daemon=True).start()
        (output / "tls-fixture.json").write_text(json.dumps({"url": f"https://127.0.0.1:{tls.server_port}/tls"}))
    env = dict(environment)
    for key in ("XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME"):
        env.pop(key, None)
    # OMP joins PI_CONFIG_DIR to homedir even when it looks absolute.
    env.update(PI_CONFIG_DIR=os.path.relpath(output / "omp-profile", Path.home()), PI_CODING_AGENT_DIR=str(output / "omp-profile/agent"),
               PI_PROFILE="default", OMP_PROFILE="default")
    command = [str(binary), "--website-captures", str(output), "--automation-url", f"http://127.0.0.1:{server.server_port}/"]
    with (output / "automation-host.log").open("w") as host_log:
        host = subprocess.Popen(command, env=env, stdout=host_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while not (output / "automation-ready.json").exists():
                if host.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Production browser host did not become ready; inspect automation-host.log")
                time.sleep(0.05)
            with (output / "automation-sdk.log").open("w") as sdk_log:
                subprocess.run(["bun", str(repo / "tests/acceptance/browser_automation.mjs"), str(output), str(package), start_at],
                               env=env, stdout=sdk_log, stderr=subprocess.STDOUT, check=True, timeout=180)
        finally:
            (output / "automation-finish").touch()
            try:
                host.wait(timeout=20)
            except subprocess.TimeoutExpired:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()
                    host.wait()
            server.shutdown()
            server.server_close()
            if tls:
                tls.shutdown()
                tls.server_close()
        if host.returncode:
            raise RuntimeError(f"Production browser host exited with {host.returncode}")
    print(f"Browser automation acceptance passed: {output}", flush=True)
