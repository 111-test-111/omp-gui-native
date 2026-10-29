"""Inspect font resources and render the three intermediate vector samples."""
import json
import os
import subprocess
from pathlib import Path
from pypdf import PdfReader

ROOT = Path(os.environ.get("OMP_GUI_VERIFICATION_OUTPUT", Path(__file__).resolve().parents[3] / "build.noindex/math-renderer-evaluation"))
rows = []
for font in ["local", "asana", "latin"]:
    path = ROOT / f"temml-{font}-sample.pdf"
    page = PdfReader(path).pages[0]
    resources = page["/Resources"]
    fonts = [str(value.get_object().get("/BaseFont")) for value in resources.get("/Font", {}).values()]
    xobjects = [str(value.get_object().get("/Subtype")) for value in resources.get("/XObject", {}).values()]
    assert fonts and "/Image" not in xobjects, (font, fonts, xobjects)
    rows.append(dict(font=font,fonts=fonts,xobjects=xobjects,box=list(map(float,page.mediabox)),text=page.extract_text()))
    subprocess.run(["pdftoppm","-r","288","-png","-singlefile",str(path),str(ROOT / f"temml-{font}-pdf-check")],check=True)
(ROOT / "pdf-validation.json").write_text(json.dumps(rows,ensure_ascii=False,indent=2)+"\n")
print(json.dumps(rows,ensure_ascii=False,indent=2))
