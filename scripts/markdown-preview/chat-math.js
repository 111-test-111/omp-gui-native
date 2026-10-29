import { mathEngine } from './math-engine.js';

// A single offscreen page supplies transparent images to native TextKit cells.
// No Markdown, prose, selection or scrolling is hosted in this WebView.
// Begin engine/font preparation while WebKit finishes navigation, before the
// first native bridge call. Rendering and preparation share the same promise.
const ready = mathEngine(true);
ready.catch(() => {});
window.chatMath = {
  async render(items, size) {
    await ready;
    MathJax.typesetClear();
    const stage = document.getElementById('stage');
    stage.replaceChildren();
    stage.style.width = 'max-content';
    stage.style.height = 'auto';
    document.documentElement.style.fontSize = `${size}px`;
    const metrics = MathJax.getMetricsFor(stage, false);
    const rows = [];
    for (const item of items) {
      const row = document.createElement('div');
      row.style.cssText = 'width:max-content;padding:4px;line-height:normal;white-space:nowrap';
      stage.append(row);
      try {
        // The public sandbox clears even global user definitions. Keep the
        // input/output jax and lazy font state instead of rebuilding each row.
        MathJax.tex2mml('\\begingroupSandbox');
        MathJax.texReset();
        const node = await MathJax.tex2chtmlPromise(item.latex, {
          ...metrics, display: item.mode === 'display', containerWidth: 100000
        });
        node.style.cssText += ';display:inline-block;margin:0;max-width:none;text-align:left';
        const baseline = document.createElement('i');
        baseline.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline';
        row.append(node, baseline);
        const error = node.querySelector('[data-mjx-error],mjx-merror');
        rows.push({row, node, baseline, error: error ? 'Unsupported or invalid LaTeX' : null});
      } catch {
        rows.push({error: 'Unsupported or invalid LaTeX'});
      }
    }
    // Direct conversion needs its dynamic CHTML/font styles published explicitly.
    MathJax.startup.document.reset();
    MathJax.startup.document.updateDocument();
    stage.getBoundingClientRect();
    // In an unshown WebView, fonts.ready can resolve before WebKit discovers
    // newly used faces. Request the actual glyphs explicitly before freezing
    // pixels; otherwise a first-use operator/font can be permanently absent.
    const fonts = new Map();
    const text = document.createTreeWalker(stage, NodeFilter.SHOW_TEXT);
    while (text.nextNode()) {
      const node = text.currentNode;
      if (!node.data.trim()) continue;
      const style = getComputedStyle(node.parentElement);
      // Load each family separately: MathJax's leading ZERO placeholder can
      // satisfy a fallback-list request while the real glyph face is unloaded.
      for (const family of style.fontFamily.split(',')) {
        const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${family.trim()}`;
        if (!fonts.has(font)) fonts.set(font, new Set());
        for (const character of node.data) fonts.get(font).add(character);
      }
    }
    await Promise.all([...fonts].map(([font, characters]) => document.fonts.load(font, [...characters].join(''))));
    await document.fonts.ready;
    // Shelf-pack the already typeset rows. A vertical strip wastes an entire
    // wide row's width on every short sibling, multiplying compositor/copy work.
    // Keep each row's own padding and TeX geometry; only its atlas origin moves.
    const tiles = rows.filter(item => item.node).map(item => ({item, box: item.row.getBoundingClientRect()}));
    const area = tiles.reduce((sum, {box}) => sum + Math.ceil(box.width) * Math.ceil(box.height), 0);
    const target = Math.max(720, Math.min(1200, Math.ceil(Math.sqrt(area) * 1.5)));
    let x = 0, y = 0, lineHeight = 0, width = 1;
    for (const {item, box} of tiles) {
      const w = Math.ceil(box.width), h = Math.ceil(box.height);
      if (x > 0 && x + w > target) { x = 0; y += lineHeight; lineHeight = 0; }
      Object.assign(item.row.style, {position: 'absolute', left: `${x}px`, top: `${y}px`});
      x += w; width = Math.max(width, x); lineHeight = Math.max(lineHeight, h);
    }
    stage.style.width = `${width}px`;
    stage.style.height = `${Math.max(1, y + lineHeight)}px`;
    const geometry = rows.map(({node, baseline, error}) => {
      if (error) return {error};
      const box = node.getBoundingClientRect();
      const y = baseline.getBoundingClientRect().top;
      const font = MathJax.startup.document.outputJax.font.params;
      return {x: box.x - 1, y: box.y - 2, width: box.width + 2, height: box.height + 4,
        descent: box.bottom - y + 2, axis: metrics.ex / font.x_height * font.axis_height};
    });
    const box = stage.getBoundingClientRect();
    return JSON.stringify({rows: geometry, width: Math.ceil(box.width), height: Math.ceil(box.height)});
  },
  clear() {
    MathJax.typesetClear();
    document.getElementById('stage').replaceChildren();
    return true;
  }
};
