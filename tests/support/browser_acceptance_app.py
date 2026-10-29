"""Compile and isolate a production-module browser host, without launching it."""
from pathlib import Path
import plistlib
import shutil
import subprocess

from catalog import Check
from support.engine import Engine
from support.local_build import clear_generated_quarantine


def prepare_browser_app(root, output, sources, suffix):
    root, output = Path(root), Path(output)
    check = Check(suffix, "Manual isolated browser acceptance", sources=tuple(sources), app=True)
    engine = Engine(root, (check,))
    engine.preflight()
    engine.current = {"id": check.id, "timeout_seconds": 120}
    (engine.outputs[check.id] / "tmp").mkdir(parents=True)
    executable = engine.compile(check)
    app = output / "OMP GUI Browser Acceptance.app"
    code = app / "Contents/MacOS"
    code.mkdir(parents=True)
    (output / "storage").mkdir(exist_ok=True)
    product = root / "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents"
    info = plistlib.loads((product / "Info.plist").read_bytes())
    original_id = info["CFBundleIdentifier"]
    info["CFBundleIdentifier"] = original_id + "." + suffix
    info["CFBundleName"] = "OMP GUI Browser Acceptance"
    info["CFBundleDisplayName"] = info["CFBundleName"]
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    binary = code / info["CFBundleExecutable"]
    shutil.copy2(executable, binary)
    for item in (product / "MacOS").iterdir():
        if item.name != binary.name:
            (code / item.name).symlink_to(item)
    subprocess.run(["/bin/cp", "-cR", str(product / "Frameworks"), str(app / "Contents/Frameworks")], check=True)
    for helper_info in (app / "Contents/Frameworks").glob("*.app/Contents/Info.plist"):
        helper = plistlib.loads(helper_info.read_bytes())
        helper["CFBundleIdentifier"] = helper["CFBundleIdentifier"].replace(original_id, info["CFBundleIdentifier"], 1)
        helper_info.write_bytes(plistlib.dumps(helper))
    (app / "Contents/Resources").symlink_to(product / "Resources")
    clear_generated_quarantine(root, app)
    return binary
