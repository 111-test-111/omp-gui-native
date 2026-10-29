"""Deterministic loopback pages; marker values are test data, not product UI."""
import json


def frame_page(labels):
    return ("<!doctype html><meta charset=utf-8><label>" + labels["Name"] +
            '<input id="frame-name"></label><button id="frame-apply">' + labels["Apply"] +
            '</button><output id="frame-output"></output><script>document.querySelector("button").onclick=()=>'
            '{document.querySelector("output").textContent=document.querySelector("input").value}</script>')


def capability_page(base, cross_base, labels):
    html = """<!doctype html><meta charset="utf-8"><style>
body{font:17px system-ui;margin:24px;background:#edf4ff;color:#12254a}input,select,button{font:inherit;padding:6px;margin:4px}#controls{padding:12px;background:white}iframe{width:44%;height:120px;border:1px solid #678}#drag{width:80px;height:45px;background:#aef;display:inline-block;touch-action:none}#drop{width:140px;height:70px;border:2px solid #2456b2;display:inline-block;margin-left:40px}#below{margin-top:1000px}#native{overflow-wrap:anywhere;font-size:12px}</style>
<h1>OMP CEF</h1><p id="native"></p>
<section id="controls"><label>__NAME__<input id="name" data-testid="main-name" placeholder="OMP"></label>
<label><input id="check" type="checkbox">CEF</label><select id="choice" aria-label="CEF"><option value="A">A</option><option value="B">B</option></select>
<button id="apply">__APPLY__</button><button id="double">CEF</button><output id="output"></output>
<input id="disabled" disabled value="CEF"><input id="upload" type="file"></section>
<article id="article"><h2>CEF</h2><p>OMP browser acceptance content.</p><a href="/download" id="download">CEF .txt</a></article>
<div id="shadow"></div><div id="drag">A</div><div id="drop">B</div>
<iframe id="same-frame" name="same" data-url="__BASE__/frame"></iframe><iframe id="cross-frame" name="cross" data-url="__CROSS__/frame"></iframe>
<button id="confirm">CEF confirm</button><button id="prompt">CEF prompt</button><button id="alert">CEF alert</button>
<div id="below">CEF</div>
<script>
const query=new URL(location.href).searchParams;window.instance=query.get('instance');window.tab=query.get('tab');
document.title='OMP CEF '+tab+' '+instance;
window.cap={double:0,hover:false,pointer:false,confirm:null,prompt:null,alert:false};
document.querySelector('#apply').onclick=()=>{document.querySelector('#output').textContent=document.querySelector('#name').value};
document.querySelector('#double').ondblclick=()=>cap.double++;
document.querySelector('#double').onmouseenter=()=>cap.hover=true;
document.querySelector('#check').onclick=()=>cap.pointer=true;
document.querySelector('#confirm').onclick=()=>cap.confirm=confirm('CEF fixture');
document.querySelector('#prompt').onclick=()=>cap.prompt=prompt('CEF fixture');
document.querySelector('#alert').onclick=()=>{alert('CEF fixture');cap.alert=true};
document.querySelector('#drag').onpointerdown=e=>{e.target.setPointerCapture(e.pointerId);window.dragging=true};
document.querySelector('#drag').onpointerup=e=>{let r=document.querySelector('#drop').getBoundingClientRect();cap.dropped=window.dragging&&e.clientX>=r.left&&e.clientX<=r.right;window.dragging=false};
document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<input id="shadow-name" aria-label="CEF shadow">';
console.log('fixture-ready');
</script>"""
    for key, value in {"__NAME__": labels["Name"], "__APPLY__": labels["Apply"], "__BASE__": base, "__CROSS__": cross_base}.items():
        html = html.replace(key, value)
    return html
