#!/usr/bin/env python3
"""Single local MCP server for explicit resource/compatibility acceptance."""
import json
import os
from pathlib import Path
import sys

log = Path(sys.argv[1])
with log.open('a') as f:
    f.write(json.dumps(dict(event='start', pid=os.getpid())) + '\n')
for line in sys.stdin:
    value = json.loads(line)
    method = value.get('method')
    with log.open('a') as f:
        f.write(json.dumps(dict(event=method, pid=os.getpid())) + '\n')
    if 'id' not in value:
        continue
    if method == 'initialize':
        result = dict(protocolVersion=value.get('params', {}).get('protocolVersion', '2024-11-05'), capabilities=dict(tools={}), serverInfo=dict(name='OMP GUI local P5 check', version='1.0.0'))
    elif method == 'tools/list':
        result = dict(tools=[dict(name='echo', description='Return the synthetic acceptance marker', inputSchema=dict(type='object', properties={}, additionalProperties=False))])
    elif method == 'tools/call':
        result = dict(content=[dict(type='text', text='P5_MCP_OK')])
    elif method == 'ping':
        result = {}
    else:
        print(json.dumps(dict(jsonrpc='2.0', id=value['id'], error=dict(code=-32601, message='Method not found'))), flush=True)
        continue
    print(json.dumps(dict(jsonrpc='2.0', id=value['id'], result=result)), flush=True)
