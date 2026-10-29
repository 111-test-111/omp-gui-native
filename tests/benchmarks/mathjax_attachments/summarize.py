"""Analyze existing results only; requires Pillow, pypdf and Poppler, not a rerun."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader

ROUTES = ("native", "pdf", "png")


def distribution(samples):
    values = sorted(samples)
    return {"count": len(values), "median": statistics.median(values),
            "p95": values[min(len(values)-1, int(len(values)*.95))], "min": min(values), "max": max(values)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, output = args.input.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    raw = {}
    for name in ["environment", "cold", "phase-evidence", "compat", *[f"{phase}-{route}" for phase in
                 ("performance", "stream", "memory", "visual") for route in ROUTES]]:
        raw[name] = json.loads((source / (name + ".json")).read_text())
    summary = {"environment": raw["environment"], "routes": {}}
    for route in ROUTES:
        compatibility = raw["compat"][route]["rows"]
        performance = raw[f"performance-{route}"]
        cold = [row for row in raw["cold"] if row["route"] == route]
        stream = raw[f"stream-{route}"]
        memory = raw[f"memory-{route}"]
        assert len(cold) == 5 and len(stream) == 6 and len(memory) == 3
        value = {
            "valid_formulas": sum(row["ok"] and row["valid"] for row in compatibility),
            "invalid_rejected": sum(not row["ok"] and not row["valid"] for row in compatibility),
            "cold_layout_ms": distribution([row["layout_ms"] for row in cold]),
            "cold_paint_ms": distribution([row["paint_ms"] for row in cold]),
            "warm": {str(count): performance[f"batch_{count}"] for count in (1,20,100)},
            "cached_layout": performance["cached_layout"], "cached_paint": performance["cached_paint"],
            "stream": {}, "memory": {},
        }
        for rate in (16,4):
            rows = [row for row in stream if row["interval_ms"] == rate]
            assert all(row["published_formulas"] == 30 for row in rows)
            assert all(row["generation_rejected_results"] == (0 if route == "native" else 1) for row in rows)
            value["stream"][str(rate)] = {
                key: distribution([sample for row in rows for sample in row[key]["samples_ms"]])
                for key in ("closure_to_paint", "main_update", "native_draw")}
            value["stream"][str(rate)]["main_with_draw"] = distribution([
                layout+draw for row in rows for layout,draw in zip(row["main_update"]["samples_ms"],row["native_draw"]["samples_ms"])])
        for phase in ("baseline", "worker_ready", "visible_100", "churn_1000", "cache_released", "worker_released"):
            rows = [next(row for row in run["phases"] if row["phase"] == phase) for run in memory]
            value["memory"][phase] = {"settled_mib": distribution([row["settled_mib"] for row in rows]),
                                      "peak_observed_mib": max(row["peak_observed_mib"] for row in rows),
                                      "cache_count": [row.get("cache_count") for row in rows],
                                      "cache_bytes": [row.get("cache_bytes") for row in rows]}
        summary["routes"][route] = value

    def inspect_resources(resources, fonts, images, embedded):
        resources = resources.get_object()
        font_resources = resources.get("/Font", {})
        if hasattr(font_resources,"get_object"): font_resources = font_resources.get_object()
        for ref in font_resources.values():
            font = ref.get_object(); fonts.add(str(font.get("/BaseFont")))
            descendants = [font, *[f.get_object() for f in font.get("/DescendantFonts", [])]]
            for item in descendants:
                descriptor = item.get("/FontDescriptor")
                if descriptor and any(key in descriptor.get_object() for key in ("/FontFile", "/FontFile2", "/FontFile3")):
                    embedded.add(str(font.get("/BaseFont")))
        xobjects = resources.get("/XObject", {})
        if hasattr(xobjects,"get_object"): xobjects = xobjects.get_object()
        for name, ref in xobjects.items():
            item = ref.get_object()
            if item.get("/Subtype") == "/Image": images.append(str(name))
            if "/Resources" in item: inspect_resources(item["/Resources"], fonts, images, embedded)

    validation = []
    for path in sorted(source.glob("pdf-atlas-*.pdf")):
        reader = PdfReader(path); fonts, images, embedded = set(), [], set()
        for page in reader.pages: inspect_resources(page["/Resources"], fonts, images, embedded)
        assert fonts and embedded and not images, (path, fonts, images)
        validation.append({"file":path.name,"fonts":sorted(fonts),"embedded_fonts":sorted(embedded),"images":images,
                           "bytes":path.stat().st_size,"pages":len(reader.pages)})
        shutil.copyfile(path, output / path.name)
        if "light" in path.name:
            subprocess.run(["pdftoppm","-r","288","-singlefile","-png",str(path),str(output / (path.stem+"-check"))],check=True)
    assert len(validation) == 4, "Expected two atlas groups in both appearances"
    summary["pdf_validation"] = validation
    (output / "summary.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2)+"\n")
    with gzip.open(output / "measurements.json.gz", "wt", encoding="utf-8") as stream:
        json.dump(raw,stream,ensure_ascii=False,separators=(",",":"))
    for route in ROUTES:
        for name in (f"{route}-696-light.png", f"{route}-280-dark.png", f"{route}-zoom-4x.png"):
            shutil.copyfile(source / name, output / name)
    # A compact common-formula comparison; complete samples remain alongside it.
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    gallery = Image.new("RGB", (2160, 952), "white")
    draw = ImageDraw.Draw(gallery)
    for index, (route,title) in enumerate(zip(ROUTES,("SwiftMath 1.7.3", "MathJax vector PDF", "MathJax PNG 2x"))):
        draw.text((index*720+12,12),title,fill="#202020",font=font)
        image = Image.open(source / f"{route}-696-light.png").convert("RGB")
        image = image.resize((720,900),Image.Resampling.LANCZOS)
        gallery.paste(image,(index*720,52))
        if index: draw.line((index*720,0,index*720,952),fill="#dddddd")
    gallery.save(output / "layout-comparison.png")
    manifest = {path.name:{"bytes":path.stat().st_size,"sha256":hashlib.sha256(path.read_bytes()).hexdigest()}
                for path in sorted(output.iterdir()) if path.is_file() and path.name != "manifest.json"}
    (output / "manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(json.dumps({route:{"cold_ms":value["cold_layout_ms"]["median"],
                            "batch100_ms":value["warm"]["100"]["paint"]["median_ms"],
                            "stream16_p95_ms":value["stream"]["16"]["closure_to_paint"]["p95"],
                            "memory100_mib":value["memory"]["visible_100"]["settled_mib"]["median"],
                            "churn_mib":value["memory"]["churn_1000"]["settled_mib"]["median"]}
                      for route,value in summary["routes"].items()},indent=2))


if __name__ == "__main__":
    main()
