"""Publish measured samples and static scientific figures in the repository."""
import csv
import argparse
import gzip
import json
import math
import os
import shutil
import statistics
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ROOT = Path(os.environ.get("OMP_GUI_VERIFICATION_OUTPUT", REPO / "build.noindex/math-renderer-evaluation"))
OUTPUT = ROOT / "published"


def load(name):
    return json.loads((ROOT / (name+".json")).read_text())


def percentiles(samples):
    ordered = sorted(samples)
    return dict(median=statistics.median(ordered), p95=ordered[math.ceil(len(ordered)*0.95)-1], n=len(ordered))


def main():
    global OUTPUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=OUTPUT)
    OUTPUT = parser.parse_args().output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    names = ["environment", "corpus", "common_ids", "cold", "memory", "jsc", "native-compat", "native-perf", "native-visual", "native-inline", "temml-copy", "pdf-validation"]
    for font in ["local", "asana", "latin"]:
        names += [f"temml-{stage}-{font}" for stage in ["compat", "perf", "visual", "inline", "attachment-perf", "pdf-perf", "atlas-perf"]]
    names += ["temml-compat-local-extensions"]
    archive = {name: load(name) for name in names}
    with (OUTPUT / "measurements.json.gz").open("wb") as stream:
        with gzip.GzipFile(filename="", fileobj=stream, mode="wb", mtime=0) as compressed:
            compressed.write((json.dumps(archive, ensure_ascii=False, sort_keys=True, separators=(",", ":"))+"\n").encode())

    native = {row["id"]: row for row in archive["native-compat"]["rows"]}
    temml = {row["id"]: row for row in archive["temml-compat-local"]["rows"]}
    extended = {row["id"]: row for row in archive["temml-compat-local-extensions"]["rows"]}
    with (OUTPUT / "compatibility.csv").open("w", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(["id", "group", "valid", "latex", "native_ok", "temml_core_ok", "temml_extensions_ok", "native_error", "temml_error"])
        for item in archive["corpus"]:
            key = item["id"]
            writer.writerow([key,item["group"],item["valid"],item["latex"],native[key]["ok"],temml[key]["ok"],extended[key]["ok"],native[key].get("error",""),temml[key].get("error","").strip().replace("\n","\\n")])
    summary = {"environment": archive["environment"], "compatibility": {}, "cold": {}, "memory": [], "assets": {}, "perf": {}}
    for engine, rows in [("native",native.values()),("temml_core",temml.values()),("temml_extensions",extended.values())]:
        rows = list(rows)
        summary["compatibility"][engine] = {group:dict(total=sum(r["group"]==group for r in rows), accepted=sum(r["group"]==group and r["ok"] for r in rows)) for group in ["core","extended","stress","invalid"]}
    for engine in ["native", "webkit"]:
        rows = [row for row in archive["cold"] if row["engine"]==engine]
        summary["cold"][engine] = {key:percentiles([row[key] for row in rows]) for key in rows[0] if key.endswith("_ms")}
        for count, views in [(0,1),(1,1),(100,1),(500,1),(100,10),(100,50)]:
            rows = [row for row in archive["memory"] if row["engine"]==engine and row["count"]==count and row["views"]==views]
            summary["memory"].append(dict(engine=engine,count=count,views=views,
                rss_mib=statistics.median(row["median_rss_mib"] for row in rows),
                footprint_mib=statistics.median(row["median_phys_footprint_mib"] for row in rows),
                footprint_min_mib=min(row["median_phys_footprint_mib"] for row in rows),
                footprint_max_mib=max(row["median_phys_footprint_mib"] for row in rows),
                launch_cpu_seconds=statistics.median(row["samples"][-1]["total_cpu_seconds"] for row in rows),
                processes=statistics.median(len(row["samples"][-1]["processes"]) for row in rows)))

    perfrows = []
    for engine in ["native", "temml-local", "temml-asana", "temml-latin"]:
        raw = archive["native-perf" if engine=="native" else "temml-perf-"+engine.split("-")[1]]
        summary["perf"][engine] = {}
        for key, value in raw.items():
            if key.startswith("batch_"):
                summary["perf"][engine][key] = {stage:dict(median=v["median_ms"],p95=v["p95_ms"],n=len(v["samples_ms"])) for stage,v in value.items()}
                for stage, v in value.items():
                    perfrows.append([engine,key,stage,v["median_ms"],v["p95_ms"],len(v["samples_ms"])])
            elif isinstance(value,dict) and "samples_ms" in value:
                summary["perf"][engine][key] = dict(median=value["median_ms"],p95=value["p95_ms"],n=len(value["samples_ms"]))
                perfrows.append([engine,key,"total",value["median_ms"],value["p95_ms"],len(value["samples_ms"])])
    for font in ["local","asana","latin"]:
        v=archive[f"temml-attachment-perf-{font}"]["shared_worker_100_sequential_images"]
        summary["perf"]["temml-"+font]["shared_100_sequential_images"] = dict(median=v["median_ms"],p95=v["p95_ms"],n=len(v["samples_ms"]))
        perfrows.append(["temml-"+font,"shared_100_sequential_images","total",v["median_ms"],v["p95_ms"],len(v["samples_ms"])])
        pdf=archive[f"temml-pdf-perf-{font}"]
        v=pdf["shared_100_sequential_pdf_attachments"]
        summary["perf"]["temml-"+font]["shared_100_sequential_pdf"] = dict(median=v["median_ms"],p95=v["p95_ms"],n=len(v["samples_ms"]),bytes_for_100=pdf["total_first_100_pdf_bytes"],representation=pdf["native_image_representation"])
        perfrows.append(["temml-"+font,"shared_100_sequential_pdf","total",v["median_ms"],v["p95_ms"],len(v["samples_ms"])])
        atlas=archive[f"temml-atlas-perf-{font}"]
        for key,value in atlas.items():
            if isinstance(value,dict) and "samples_ms" in value:
                summary["perf"]["temml-"+font][key]=dict(median=value["median_ms"],p95=value["p95_ms"],n=len(value["samples_ms"]))
                perfrows.append(["temml-"+font,key,"total",value["median_ms"],value["p95_ms"],len(value["samples_ms"])])
        summary["perf"]["temml-"+font]["atlas_pdf_bytes"]=statistics.median(atlas["pdf_bytes"])
    with (OUTPUT / "performance.csv").open("w",newline="") as stream:
        writer=csv.writer(stream,lineterminator="\n");writer.writerow(["engine","scenario","stage","median_ms","p95_ms","samples"]);writer.writerows(perfrows)
    dist=ROOT/"vendor/package/dist"
    bundles=list((REPO/"build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents/Resources").rglob("SwiftMath_SwiftMath.bundle"))
    summary["assets"]["native_shipped_bundle_bytes"]=sum(p.stat().st_size for p in bundles[0].rglob("*") if p.is_file()) if bundles else None
    for font, files in {
        "temml-local":["temml.min.js","Temml-Local.css","Temml.woff2"],
        "temml-asana":["temml.min.js","Temml-Asana.css","Asana-Math.otf"],
        "temml-latin":["temml.min.js","Temml-Latin-Modern.css","Temml.woff2","latinmodern-math.otf"],
        "temml-extensions":["mhchem.min.js","physics.js"],
    }.items():
        summary["assets"][font] = dict(total_bytes=sum((dist/name).stat().st_size for name in files),files={name:(dist/name).stat().st_size for name in files})
    (OUTPUT/"summary.json").write_text(json.dumps(summary,ensure_ascii=False,indent=2)+"\n")
    for name in ["swiftmath-light","swiftmath-dark","swiftmath-inline"] + [f"temml-{font}-{appearance}" for font in ["local","asana","latin"] for appearance in ["light","dark","inline"]]:
        shutil.copyfile(ROOT/(name+".png"), OUTPUT/(name+".png"))
    for font in ["local","asana","latin"]:
        shutil.copyfile(ROOT/f"temml-{font}-atlas.png",OUTPUT/f"temml-{font}-atlas.png")
        shutil.copyfile(ROOT/f"temml-{font}-atlas-screen.png",OUTPUT/f"temml-{font}-atlas-screen.png")

    # Scientific figures use the raw medians, with no smoothing or inferred runs.
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size":11,"axes.spines.top":False,"axes.spines.right":False})
    fig,axes=plt.subplots(1,2,figsize=(12,4.2),layout="constrained")
    sizes=[1,20,100,500]
    for engine,label,color in [("native","SwiftMath / native","#2c7098"),("temml-local","Temml / WKWebView","#dc7641")]:
        stage="textkit_layout" if engine=="native" else "bridge_to_layout"
        values=[summary["perf"][engine][f"batch_{n}"][stage]["median"] for n in sizes]
        axes[0].plot(sizes,values,"o-",label=label,color=color)
        rows=[row for row in summary["memory"] if row["engine"]==("native" if engine=="native" else "webkit") and row["count"]==100]
        values=[next(row["footprint_mib"] for row in rows if row["views"]==v) for v in [1,10,50]]
        axes[1].plot([1,10,50],values,"o-",label=label,color=color)
    axes[0].set(xscale="log",yscale="log",xlabel="New formulas per batch",ylabel="Median to completed layout (ms)",title="Warm pipeline, 28 common fixtures")
    axes[1].set(xscale="log",yscale="log",xlabel="Views holding 100 formulas",ylabel="Summed physical footprint (MiB)",title="Host + newly created WebKit services")
    for ax in axes:
        ax.grid(alpha=.15);ax.legend(frameon=False,fontsize=9)
    fig.savefig(OUTPUT/"benchmark.png",dpi=160)
    fig.savefig(OUTPUT/"benchmark.svg")
    svg=OUTPUT/"benchmark.svg"
    svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines())+"\n")
    plt.close(fig)

    from PIL import Image,ImageDraw,ImageFont
    fontfile=Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    font=ImageFont.truetype(str(fontfile),22) if fontfile.exists() else ImageFont.load_default()
    columns=[("SwiftMath / Asana","swiftmath-light"),("Temml / Asana","temml-asana-light"),("Temml / Latin Modern","temml-latin-light")]
    selected=[(0,"Quadratic"),(2,"Indexed root"),(4,"Wide accents"),(6,"Matrix"),(7,"Cases")]
    sheet=Image.new("RGB",(1920,790),"white");draw=ImageDraw.Draw(sheet)
    for column,(title,name) in enumerate(columns):
        source=Image.open(OUTPUT/(name+".png")).convert("RGB")
        assert source.size==(1440,2200), (name,source.size)
        draw.text((column*640+16,12),title,fill="#202020",font=font)
        for row,(index,label) in enumerate(selected):
            y=52+row*146
            draw.text((column*640+16,y),label,fill="#606060",font=font)
            sheet.paste(source.crop((400,index*180+64,1040,index*180+176)),(column*640,y+28))
    sheet.save(OUTPUT/"layout-comparison.png")
    print(json.dumps({"output":str(OUTPUT),"cold":summary["cold"],"memory":summary["memory"]},ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()
