// Research worker only. The production preview bootstraps MathJax and serves
// every script/font; these functions use its public conversion API.
window.attachmentPrototype = {
  async render(items, size, dark) {
    MathJax.typesetClear();
    // Isolate each job's TeX definitions, retaining the output jax/font state.
    const startup = MathJax.startup;
    startup.input = startup.getInputJax();
    startup.document = startup.getDocument();
    startup.makeMethods();
    document.getElementById('document').replaceChildren();
    document.documentElement.style.cssText = `font-size:${size}px;background:transparent;color:${dark ? '#fff' : '#000'}`;
    document.body.style.cssText = 'margin:0;background:transparent;overflow:visible';
    let stage = document.getElementById('attachment-stage');
    if (!stage) {
      stage = document.createElement('div');
      stage.id = 'attachment-stage';
      document.body.append(stage);
    }
    stage.style.cssText = 'position:absolute;left:0;top:0;width:max-content;max-width:none;padding:0;margin:0;white-space:nowrap';
    stage.replaceChildren();
    // Metrics force a browser layout. The surrounding font is identical for
    // every row, so obtain it once before mutating the stage, not once per TeX.
    const metrics = MathJax.getMetricsFor(stage, false);
    const rows = [];
    for (const item of items) {
      const row = document.createElement('div');
      row.style.cssText = 'width:max-content;max-width:none;padding:4px;line-height:normal;white-space:nowrap';
      stage.append(row);
      try {
        const node = await MathJax.tex2chtmlPromise(item.latex, {
          ...metrics, display: item.mode === 'display', containerWidth: 100000
        });
        node.style.cssText += ';display:inline-block;margin:0;max-width:none;text-align:left';
        const baseline = document.createElement('i');
        baseline.style.cssText = 'display:inline-block;width:0;height:0;padding:0;vertical-align:baseline';
        row.append(node, baseline);
        const error = node.querySelector('[data-mjx-error],mjx-merror');
        rows.push({row, node, baseline, error: error?.getAttribute('data-mjx-error') || (error ? 'Invalid TeX' : null)});
      } catch (error) {
        rows.push({row, error: String(error)});
      }
    }
    // Conversion calls do not insert MathItems into the document. Explicitly
    // publish the dynamic font/CHTML CSS before measuring or exporting nodes.
    MathJax.startup.document.reset();
    MathJax.startup.document.updateDocument();
    stage.getBoundingClientRect();
    await document.fonts.ready;
    const geometry = rows.map(({node, baseline, error}) => {
      if (error) return {error};
      const box = node.getBoundingClientRect();
      const y = baseline.getBoundingClientRect().top;
      return {x:box.x-2,y:box.y-2,width:box.width+4,height:box.height+4,
        ascent:y-box.y+2,descent:box.bottom-y+2};
    });
    const box = stage.getBoundingClientRect();
    return JSON.stringify({rows:geometry,width:Math.ceil(box.width),height:Math.ceil(box.height),
      version:MathJax.version,stylesheets:document.styleSheets.length,fonts:document.fonts.size});
  },
  clear() {
    MathJax.typesetClear();
    document.getElementById('attachment-stage')?.replaceChildren();
    return true;
  }
};
