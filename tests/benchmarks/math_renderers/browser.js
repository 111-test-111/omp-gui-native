/* This harness calls Temml directly, retaining the application's TeX boundaries. */
const content = document.getElementById("content");
const options = mode => ({ displayMode: mode === "display", throwOnError: true,
  trust: false, maxExpand: 1000, maxSize: [50, 1000] });
let cachedMarkup = "";

function renderBatch(items) {
  const start = performance.now();
  const markup = items.map(item => `<div class="formula">${temml.renderToString(item.latex, options(item.mode))}</div>`).join("");
  const converted = performance.now();
  content.innerHTML = markup;
  cachedMarkup = markup;
  const height = content.offsetHeight;
  const width = content.scrollWidth;
  return JSON.stringify({ convert_ms: converted-start, total_js_layout_ms: performance.now()-start, height, width });
}

function renderCached() {
  content.innerHTML = cachedMarkup;
  return JSON.stringify({ height: content.offsetHeight, width: content.scrollWidth });
}

function compat(items) {
  const rows = items.map(item => {
    const row = { id: item.id, group: item.group, valid: item.valid };
    const host = document.createElement("div");
    host.style.cssText = "display:block;width:max-content;";
    content.append(host);
    const t = performance.now();
    try {
      host.innerHTML = temml.renderToString(item.latex, options(item.mode));
      // Some unsupported commands produce error-coloured output even with throwOnError.
      const degraded = host.querySelector(".temml-error, .tml-error, mtext[mathcolor]");
      const box = host.getBoundingClientRect();
      row.ok = box.height > 0 && !!host.querySelector("math") && !degraded;
      row.width = box.width; row.height = box.height;
      row.mathml = host.innerHTML;
      row.text = host.textContent;
      if (degraded) row.error = "error output";
    } catch(error) { row.ok = false; row.error = error.message; }
    row.ms = performance.now()-t;
    return row;
  });
  return JSON.stringify(rows);
}

function visual(items) {
  document.body.classList.add("visual");
  content.innerHTML = "";
  for (const item of items) {
    const section = document.createElement("section");
    section.dataset.id = item.id;
    const label = document.createElement("div");
    label.className = "label"; label.textContent = item.id;
    section.append(label);
    const row = document.createElement("div"); row.className = "example";
    const span = document.createElement("span");
    try { span.innerHTML = temml.renderToString(item.latex, options(item.mode)); }
    catch(error) { span.textContent = item.latex; span.className = "fallback"; }
    row.append(span);
    section.append(row); content.append(section);
  }
  return document.body.offsetHeight;
}

function visualGeometry() {
  return JSON.stringify([...content.querySelectorAll("section")].map(section => {
    const row = section.querySelector(".example"), math = section.querySelector("math");
    return {id:section.dataset.id, height:row.getBoundingClientRect().height,
      scrollWidth:row.scrollWidth, mathHeight:math?.getBoundingClientRect().height,
      font:math ? getComputedStyle(math).fontFamily : null};
  }));
}

function linebreakProbe() {
  const tex = Array.from({length:30}, (_,i) => `a_{${i+1}}`).join("+")+"=S";
  const result = [];
  content.innerHTML = "";
  for (const width of [696, 280]) {
    for (const mode of [false, true]) {
      for (const annotate of [false, true]) {
        const row = document.createElement("div");
        row.style.cssText=`width:${width}px;font-size:15px`;
        row.innerHTML=temml.renderToString(tex, {displayMode:mode,wrap:"tex",annotate,throwOnError:true});
        content.append(row);
        const range=document.createRange(); range.selectNodeContents(row);
        const math=row.querySelector("math");
        result.push({width,display:mode,annotate,height:row.offsetHeight,scrollWidth:row.scrollWidth,
          mathHeight:math.getBoundingClientRect().height,mathWidth:math.getBoundingClientRect().width,
          selection:window.getSelection().toString(),annotation:!!math.querySelector("annotation")});
      }
    }
  }
  const math=content.querySelector("math"), range=document.createRange();range.selectNodeContents(math);
  const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
  return JSON.stringify({rows:result,selectedText:selection.toString(),tex});
}

function inlineVisual(items) {
  document.body.className="inline-visual";
  content.innerHTML="";
  for (const width of [696,280]) {
    const column=document.createElement("div");column.className="column";column.style.width=width+"px";
    const heading=document.createElement("div");heading.className="heading";heading.textContent=width+" pt";column.append(heading);
    for (const item of items) {
      const section=document.createElement("section");section.dataset.id=item.id;
      const label=document.createElement("div");label.className="label";label.textContent=item.id;
      const row=document.createElement("div");row.className="example";
      row.append("中文 English 前文 ");
      const math=document.createElement("span");
      try { math.innerHTML=temml.renderToString(item.latex,options("inline")); }
      catch(error) { math.textContent="$"+item.latex+"$";math.className="fallback"; }
      row.append(math," 后文正常换行。");
      section.append(label,row);column.append(section);
    }
    content.append(column);
  }
  return document.body.offsetHeight;
}

function inlineGeometry() {
  return JSON.stringify([...content.querySelectorAll(".column")].flatMap(column=>[...column.querySelectorAll("section")].map(section=>{
    const row=section.querySelector(".example"), math=section.querySelector("math");
    return {id:section.dataset.id,width:column.offsetWidth,scrollWidth:row.scrollWidth,
      height:row.getBoundingClientRect().height, mathHeight:math?.getBoundingClientRect().height};
  })));
}

function workerRender(item) {
  document.body.className="";content.style.width="max-content";
  content.innerHTML=temml.renderToString(item.latex,options(item.mode))+"<i id='baseline' style='display:inline-block;width:0;height:0;vertical-align:baseline'></i>";
  const math=content.querySelector("math");math.style.display="inline";math.style.width="auto";
  const box=math.getBoundingClientRect(),baseline=document.getElementById("baseline").getBoundingClientRect().top;
  return JSON.stringify({x:box.x,y:box.y,width:box.width,height:box.height,ascent:baseline-box.top,descent:box.bottom-baseline});
}

function copyProbe() {
  const latex="\\frac{a+b}{c+d}";
  const results=[];
  for (const mode of ["inline","display"]) {
    content.innerHTML="中文 before "+temml.renderToString(latex,{...options(mode),annotate:true})+" after";
    const selection=window.getSelection(),range=document.createRange();range.selectNodeContents(content);
    selection.removeAllRanges();selection.addRange(range);
    const data={},event=new Event("copy",{bubbles:true,cancelable:true});
    Object.defineProperty(event,"clipboardData",{value:{setData:(type,value)=>{data[type]=value;}}});
    document.dispatchEvent(event);
    results.push({mode,plain:data["text/plain"],prevented:event.defaultPrevented});
  }
  return JSON.stringify(results);
}

function atlasRender(items) {
  content.style.width="696px";content.innerHTML="";
  for (const item of items) {
    const row=document.createElement("div");row.style.cssText="margin:0 0 8px;width:max-content";
    row.innerHTML=temml.renderToString(item.latex,options(item.mode))+"<i style='display:inline-block;width:0;height:0;vertical-align:baseline'></i>";
    const math=row.querySelector("math");math.style.display="inline";math.style.width="auto";
    content.append(row);
  }
  return JSON.stringify({width:720,height:document.body.scrollHeight,
    rows:[...content.children].map(row=>{
      const box=row.querySelector("math").getBoundingClientRect();
      return {x:box.x-2,y:box.y-2,width:box.width+4,height:box.height+4};
    })});
}
