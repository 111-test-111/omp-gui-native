import { mathEngine } from './math-engine.js';
import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import texmath from 'markdown-it-texmath';
import DOMPurify from 'dompurify';
import { hljs, languageForInfo } from './syntax-languages.js';

const article = document.getElementById('document');
const post = value => window.webkit?.messageHandlers.preview?.postMessage(value);
let current = '', pending, running = false, mathHasRendered = false, restored = false, positionTimer;
const md = new MarkdownIt({ html: true, linkify: true, breaks: false,
  highlight(code, language) {
    language = languageForInfo(language);
    if (code.length <= 65536 && language && hljs.getLanguage(language)) {
      try { return hljs.highlight(code, { language, ignoreIllegals: true }).value; } catch {}
    }
    return '';
  }
}).use(footnote);
const escape = md.utils.escapeHtml;
// Keep image paths inert until the native resource loader resolves them. This
// also prevents an initial request relative to the bundled HTML document.
DOMPurify.addHook('beforeSanitizeAttributes', node => {
  if (node.nodeName !== 'IMG') return;
  const source = node.getAttribute('src');
  node.removeAttribute('src');
  if (source !== null) node.setAttribute('data-image-source', source);
});
const validateLink = md.validateLink;
md.validateLink = url => /^file:/i.test(url) || validateLink(url);

// Use texmath only for delimiter tokenization, before Markdown can consume TeX
// escapes. Rendering is exclusively MathJax 4; original source stays on tokens.
const mathRules = texmath.mergeDelimiters(['dollars', 'brackets', 'beg_end']);
for (const [index, rule] of mathRules.inline.entries()) {
  const parse = texmath.inline(rule);
  md.inline.ruler.before('escape', `omp_math_inline_${index}`, (state, silent) => {
    const start = state.pos;
    if (!parse(state, silent)) return false;
    if (!silent) state.tokens.at(-1).meta = { source: state.src.slice(start, state.pos), display: !!rule.displayMode };
    return true;
  });
}
for (const [index, rule] of mathRules.block.entries()) {
  const parse = texmath.block(rule);
  md.block.ruler.before('fence', `omp_math_block_${index}`, (state, line, end, silent) => {
    const start = state.bMarks[line] + state.tShift[line];
    if (!parse(state, line, end, silent)) return false;
    if (!silent) state.tokens.at(-1).meta = { source: state.src.slice(start, rule.rex.lastIndex), display: true };
    return true;
  });
}
for (const rule of [...mathRules.inline, ...mathRules.block]) {
  md.renderer.rules[rule.name] = (tokens, i) => {
    const t = tokens[i], display = t.meta.display;
    const tex = t.content + (t.type.endsWith('_eqno') ? `\\tag{${t.info}}` : '');
    const input = (display ? '\\[' : '\\(') + tex + (display ? '\\]' : '\\)');
    return `<span class="math ${display ? 'math-display' : 'math-inline'}" data-source="${escape(t.meta.source)}" data-latex="${escape(tex)}">${escape(input)}</span>`;
  };
}

function markdown(source, labels) {
  // Frontmatter is document metadata, never a Setext heading. Only consume a
  // closed block at the beginning; preserve the complete metadata verbatim.
  const front = source.match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/);
  const prefix = front ? `<pre class="frontmatter" aria-label="${escape(labels.metadata)}">${escape(front[1])}</pre>` : '';
  const environment = {};
  const tokens = md.parse(front ? source.slice(front[0].length) : source, environment);
  const slugs = new Map();
  let quoteDepth = 0;
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].type === 'blockquote_open') quoteDepth++;
    if (tokens[i].type === 'blockquote_close') quoteDepth--;
    if (quoteDepth && tokens[i].type === 'inline') {
      // Preserve the author's lines inside a quote without changing paragraph,
      // code-span or TeX parsing elsewhere in the document.
      for (const child of tokens[i].children || []) {
        if (child.type === 'softbreak') child.type = 'hardbreak';
      }
    }
    if (['th_open', 'td_open'].includes(tokens[i].type)) {
      const alignment = tokens[i].attrGet('style')?.match(/^text-align:(left|center|right)$/)?.[1];
      if (alignment) tokens[i].attrSet('align', alignment);
    }
    if (tokens[i].type === 'heading_open') {
      const text = (tokens[i+1]?.children || []).filter(t => t.type !== 'html_inline').map(t => t.content).join('');
      const slug = text.toLowerCase().trim().replace(/[^\p{L}\p{N}\p{M}_\-\s]/gu, '').replace(/\s/g, '-');
      let id = slug, n = 0;
      while (slugs.has(id)) id = `${slug}-${++n}`;
      slugs.set(id, true); tokens[i].attrSet('id', id);
    }
    if (tokens[i].type === 'inline' && tokens[i-1]?.type === 'paragraph_open' && tokens[i-2]?.type === 'list_item_open') {
      const first = tokens[i].children?.[0], match = first?.type === 'text' && first.content.match(/^\[([ xX])\]\s+/);
      if (match) {
        first.content = first.content.slice(match[0].length);
        const box = new tokens[i].constructor('html_inline', '', 0);
        box.content = `<input type="checkbox" disabled ${match[1] !== ' ' ? 'checked' : ''}>`;
        tokens[i].children.unshift(box); tokens[i-2].attrJoin('class', 'task-list-item');
      }
    }
  }
  // One parse and one environment for the entire document: links and footnotes
  // resolve once and can never leak their definitions into individual paragraphs.
  return prefix + md.renderer.render(tokens, md.options, environment);
}


async function prepareImages(token) {
  const images = [...article.querySelectorAll('img')];
  // Metadata reserves the real aspect ratio before restoring a deep scroll
  // position; only viewport images are decoded. Bound metadata concurrency.
  for (let offset = 0; offset < images.length; offset += 6) {
    if (pending || current !== token) return;
    await Promise.all(images.slice(offset, offset + 6).map(async img => {
      const path = img.getAttribute('data-image-source') || '';
      img.removeAttribute('data-image-source');
      if (!path) { img.replaceWith(document.createTextNode(img.alt)); return; }
      if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(path) && !/^file:/i.test(path)) {
        const link = document.createElement('a'); link.textContent = img.alt || path;
        if (/^https?:/i.test(path)) link.href = path;
        img.replaceWith(link); return;
      }
      const url = `omp-preview://image/${token}?path=${encodeURIComponent(path)}`;
      img.loading = 'lazy'; img.decoding = 'async';
      img.removeAttribute('srcset');
      img.addEventListener('error', () => { img.replaceWith(document.createTextNode(img.alt || path)); }, { once: true });
      try {
        const response = await fetch(url + '&info=1');
        const size = await response.json();
        if (size.width > 0 && size.height > 0) { img.width = size.width; img.height = size.height; }
      } catch { /* The alt text remains available for unreadable images. */ }
      // Reserve layout before WebKit decides which lazy images are near view.
      if (!pending && current === token) img.src = url;
    }));
  }
}

function selectionPosition() {
  const selected = getSelection();
  if (!selected?.rangeCount || !article.contains(selected.anchorNode) || !article.contains(selected.focusNode)) return { selectionLocation: 0, selectionLength: 0 };
  const range = selected.getRangeAt(0), before = document.createRange();
  before.selectNodeContents(article); before.setEnd(range.startContainer, range.startOffset);
  return { selectionLocation: before.toString().length, selectionLength: range.toString().length };
}
function readingPosition() {
  return restored ? { type: 'position', token: current, x: scrollX, y: scrollY, ...selectionPosition() } : null;
}
function savePosition() {
  const position = readingPosition(); if (position) post(position);
}
function restore(position) {
  const start = Math.max(0, position.selectionLocation || 0), end = start + Math.max(0, position.selectionLength || 0);
  if (end > start) {
    const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
    let node, offset = 0, range = document.createRange(), began = false;
    while ((node = walker.nextNode())) {
      const next = offset + node.length;
      if (!began && start <= next) { range.setStart(node, start - offset); began = true; }
      if (began && end <= next) { range.setEnd(node, end - offset); getSelection().removeAllRanges(); getSelection().addRange(range); break; }
      offset = next;
    }
  }
  scrollTo(position.x || 0, position.y || 0); restored = true;
}

async function render(job) {
  const started = performance.now();
  document.documentElement.dataset.phase = "parse";
  current = job.token; restored = false;
  clearTimeout(positionTimer);
  window.MathJax?.typesetClear?.([article]);
  const raw = markdown(job.source, job.labels);
  article.innerHTML = DOMPurify.sanitize(raw, {
    ALLOWED_TAGS: ['p','div','span','h1','h2','h3','h4','h5','h6','a','img','em','strong','del','s','br','hr','code','pre',
      'blockquote','ul','ol','li','table','thead','tbody','tr','th','td','sup','sub','details','summary','section','input','kbd','mark','dl','dt','dd'],
    ALLOWED_ATTR: ['id','class','href','src','alt','title','start','align','colspan','rowspan','type','checked','disabled','data-source','data-latex','data-image-source'],
    ALLOW_DATA_ATTR: false,
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|file):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i
  });
  // Includes the automatic footnote separator after a trailing source rule.
  for (const rule of article.querySelectorAll('hr + hr')) rule.remove();
  for (const table of article.querySelectorAll('table')) {
    const wrapper = document.createElement('div'); wrapper.className = 'table-scroll'; table.replaceWith(wrapper); wrapper.append(table);
  }
  const formulas = [...article.querySelectorAll('.math')];
  const imagesReady = prepareImages(job.token);
  if (formulas.length) {
    try {
      document.documentElement.dataset.phase = "engine";
      await mathEngine();
      if (pending) return;
      // A fresh input/document isolates macros and equation labels. Reuse the
      // output jax and its font metrics instead of rebuilding every font object
      // on a tab switch. These are MathJax's public startup component methods.
      if (mathHasRendered) {
        const startup = MathJax.startup;
        startup.input = startup.getInputJax();
        startup.document = startup.getDocument();
        startup.makeMethods();
      }
      mathHasRendered = true;
      document.documentElement.dataset.phase = "math";
      await MathJax.typesetPromise([article]);
      for (const element of formulas) {
        element.setAttribute('role', 'math');
        element.setAttribute('aria-label', element.dataset.latex);
        if (!element.querySelector('mjx-container') || element.querySelector('[data-mjx-error], mjx-merror')) {
          element.dataset.mathError = element.querySelector('[data-mjx-error]')?.getAttribute('data-mjx-error') || 'Unparsed TeX';
          element.textContent = element.dataset.source;
          element.classList.add('math-error');
        }
      }
    } catch {
      for (const element of formulas) { element.textContent = element.dataset.source; element.classList.add('math-error'); }
    }
  }
  document.documentElement.dataset.phase = "images";
  await imagesReady;
  document.documentElement.dataset.phase = "fonts";
  article.getBoundingClientRect();
  await document.fonts.ready;
  if (pending) return;
  restore(job.position);
  document.documentElement.dataset.phase = "ready";
  document.documentElement.dataset.rendered = job.token;
  post({ type: 'rendered', token: job.token, milliseconds: performance.now() - started,
    formulas: formulas.length, errors: article.querySelectorAll('.math-error').length });
}

window.preview = {
  render(job) {
    pending = job;
    if (running) return;
    running = true;
    (async () => {
      try {
        while (pending) { const next = pending; pending = null; await render(next); }
      } catch { post({ type: 'error', token: current }); }
      finally { running = false; }
    })();
  },
  theme(colors) { for (const [key, value] of Object.entries(colors)) document.documentElement.style.setProperty('--' + key, value); },
  position: savePosition,
  readingPosition
};
for (const name of ['scroll', 'selectionchange']) document.addEventListener(name, () => {
  clearTimeout(positionTimer); positionTimer = setTimeout(savePosition, 100);
}, { passive: true });
document.addEventListener('mouseup', savePosition);
document.addEventListener('keydown', event => {
  if (event.metaKey && event.key.toLowerCase() === 'f') { event.preventDefault(); post({ type: 'find' }); }
});
document.addEventListener('click', event => {
  const link = event.target.closest('a');
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href') || '';
  if (href.startsWith('#')) {
    let fragment; try { fragment = decodeURIComponent(href.slice(1)); } catch { return; }
    const target = document.getElementById(fragment);
    if (target) { target.scrollIntoView(); savePosition(); return; }
  }
  post({ type: 'link', token: current, href });
});
document.addEventListener('contextmenu', event => {
  const math = event.target.closest('.math');
  if (math) { event.preventDefault(); post({ type: 'mathMenu', latex: math.dataset.latex, x: event.clientX, y: event.clientY }); }
});

function copiedFragment() {
  const selection = getSelection();
  if (!selection?.rangeCount || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0).cloneRange();
  const mathParent = node => (node.nodeType === 1 ? node : node.parentElement)?.closest('.math');
  const first = mathParent(range.startContainer), last = mathParent(range.endContainer);
  if (first) range.setStartBefore(first);
  if (last) range.setEndAfter(last);
  const container = document.createElement('div'); container.append(range.cloneContents());
  for (const math of container.querySelectorAll('.math')) math.replaceWith(document.createTextNode(math.dataset.source));
  for (const img of container.querySelectorAll('img')) img.replaceWith(document.createTextNode(img.alt));
  for (const backref of container.querySelectorAll('.footnote-backref')) backref.remove();
  return container;
}
function plainText(node) {
  if (node.nodeType === 3) return node.textContent;
  if (node.nodeName === 'BR') return '\n';
  const value = [...node.childNodes].map(plainText).join('');
  if (/^(P|DIV|H[1-6]|LI|PRE|BLOCKQUOTE|TR|SECTION|DETAILS)$/.test(node.nodeName)) return value + '\n';
  if (/^(TD|TH)$/.test(node.nodeName)) return value + '\t';
  return value;
}
window.preview.selectedText = () => { const fragment = copiedFragment(); return fragment ? plainText(fragment).trimEnd() : ''; };
document.addEventListener('copy', event => {
  const fragment = copiedFragment(); if (!fragment) return;
  event.clipboardData.setData('text/plain', plainText(fragment).trimEnd());
  event.clipboardData.setData('text/html', fragment.innerHTML);
  event.preventDefault();
});
post({ type: 'ready' });
