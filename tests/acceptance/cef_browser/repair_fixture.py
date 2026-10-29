"""Pixel-distinct targets in genuinely nested cross-site frames."""
from html import escape


def repair_page(base, cross_base):
    return f'''<!doctype html><meta charset=utf-8><style>
body{{margin:0;background:#ff00aa;min-width:1700px;min-height:2800px}}
iframe{{display:block;width:560px;height:240px;border:8px solid #333;padding:12px;margin-left:240px;margin-top:760px}}
#native{{width:800px;overflow-wrap:anywhere}}
#reference{{position:absolute;left:0;top:0;width:180px;height:100px;display:grid;grid-template-columns:1fr 1fr}}
</style><div id=reference><i style="background:#d12233"></i><i style="background:#22b755"></i><i style="background:#2244cc"></i><i style="background:#ffc300"></i></div><p id=native></p>
<iframe id=same-shot name=same-shot src="{base}/repair-frame?kind=same"></iframe>
<iframe id=cross-shot name=cross-shot src="{cross_base}/repair-frame?kind=cross"></iframe>
<iframe id=nested-shot name=nested-shot src="{base}/repair-frame?kind=parent"></iframe>
<script>document.title='OMP CEF '+new URL(location.href).searchParams.get('instance');console.log('fixture-ready');</script>'''


def repair_frame(kind, cross_base):
    if kind == 'parent':
        return f'''<!doctype html><meta charset=utf-8><style>
body{{margin:0;min-height:1500px;background:#912a95}}
iframe{{margin:380px 0 0 24px;width:440px;height:180px;border:6px solid #222;padding:10px}}
</style><iframe name=nested-child src="{cross_base}/repair-frame?kind=nested"></iframe>'''
    return f'''<!doctype html><meta charset=utf-8><style>
body{{margin:0;background:#18bbc5;min-width:650px;min-height:1500px}}
#capture-target{{margin:450px 0 0 170px;width:180px;height:100px;position:relative}}
.q{{width:50%;height:50%;position:absolute}}.a{{background:#d12233;left:0;top:0}}
.b{{background:#22b755;right:0;top:0}}.c{{background:#2244cc;left:0;bottom:0}}
.d{{background:#ffc300;right:0;bottom:0}}
</style><div id=capture-target aria-label="{escape(kind)}"><i class="q a"></i><i class="q b"></i><i class="q c"></i><i class="q d"></i></div>
<input id=frame-name><output id=frame-output>{escape(kind)}</output>'''
