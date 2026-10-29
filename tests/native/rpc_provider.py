#!/usr/bin/env python3
"""Run production Swift/native OMP against an isolated local deterministic provider."""
import argparse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
import time
import uuid
from zoneinfo import ZoneInfo


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        messages = body.get('messages', [])
        users = [m for m in messages if m.get('role') == 'user']
        content = users[-1].get('content', '') if users else ''
        user_text = content if isinstance(content, str) else ''.join(part.get('text', '') for part in content if isinstance(part, dict))
        with self.server.record_lock:
            with self.server.log_path.open('a') as log:
                log.write(json.dumps({'path': self.path, 'user': content}, ensure_ascii=False) + '\n')
        if 'P5_HOLD' in str(content):
            time.sleep(1)
        if 'P5_WORKER_HOLD' in str(content):
            time.sleep(1)
        if 'P5_WORKER_STEER' in str(content):
            time.sleep(10)
        if 'GOAL_NATIVE_HOLD' in str(content):
            time.sleep(2)
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            base = dict(id='p5-' + uuid.uuid4().hex, object='chat.completion.chunk', created=int(time.time()), model='forward')
            reply = ('P5_REPLY:' + ''.join(hashlib.sha256(f'p5-{i}'.encode()).hexdigest() + ' 数据🙂\n' for i in range(25_000))) if 'P5_NATIVE_LARGE' in str(content) else 'P5_REPLY'
            # Keep provider events realistic: native RPC chunking is exercised by
            # the completed message/history, rather than one enormous SSE event.
            output_tokens = max(8, len(reply) // 2)
            if 'GOAL_NATIVE_COMPLETE' in user_text and messages[-1].get('role') == 'user':
                delta = dict(role='assistant', tool_calls=[dict(index=0, id='native-goal-complete', type='function',
                             function=dict(name='goal', arguments=json.dumps(dict(op='complete'))))])
                frames = [dict(base, choices=[dict(index=0, delta=delta, finish_reason=None)])]
                finish = 'tool_calls'
            elif user_text == 'P5_WORKER_PARENT' and messages[-1].get('role') == 'user':
                arguments = dict(agent='p5-worker', task='P5_WORKER_HOLD', name='forwardworker',
                                 solutionSpace='Only this new isolated local acceptance fixture', isolated=False)
                delta = dict(role='assistant', tool_calls=[dict(index=0, id='p5-native-worker', type='function',
                             function=dict(name='task', arguments=json.dumps(arguments)))])
                frames = [dict(base, choices=[dict(index=0, delta=delta, finish_reason=None)])]
                finish = 'tool_calls'
            elif user_text == 'P5_DEFERRED_CONTEXT' and messages[-1].get('role') == 'user':
                # Match the real failure: native todo rejects append without a
                # phase name and parks a todo-error-reminder for the next prompt.
                arguments = dict(op='append', items=['Deferred-context regression'])
                delta = dict(role='assistant', tool_calls=[dict(index=0, id='native-invalid-todo', type='function',
                             function=dict(name='todo', arguments=json.dumps(arguments)))])
                frames = [dict(base, choices=[dict(index=0, delta=delta, finish_reason=None)])]
                finish = 'tool_calls'
            else:
                frames = [dict(base, choices=[dict(index=0, delta=dict(role='assistant', content=reply[i:i + 4096]), finish_reason=None)]) for i in range(0, len(reply), 4096)]
                finish = 'stop'
            frames.append(dict(base, choices=[dict(index=0, delta={}, finish_reason=finish)], usage=dict(prompt_tokens=64, completion_tokens=output_tokens, total_tokens=64 + output_tokens)))
            for frame in frames:
                self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode())
                self.wfile.flush()
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--omp', action='append', required=True, help='Actual OMP executable; repeat for a version matrix')
    parser.add_argument('--helper', type=Path, required=True, help='Helper compiled by tests/run.py')
    parser.add_argument('--output', type=Path, required=True, help='Fresh output from tests/run.py')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    products = repo / 'build.noindex/development/Build/Products/Debug'
    code = products / 'OMP GUI Dev.app/Contents/MacOS'
    output = args.output.resolve()
    if not output.is_relative_to(repo / 'build.noindex/verification/runs'):
        parser.error('Require isolated runner output under build.noindex/verification/runs')
    output.mkdir(parents=True, exist_ok=True)
    runner = args.helper.resolve()
    summaries = []
    for index, binary in enumerate(args.omp):
        binary = str(Path(binary).resolve())
        version = subprocess.check_output([binary, '--version'], text=True, timeout=15).strip().removeprefix('omp/')
        binary_hash = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
        run = output / f'runtime-{index}-{binary_hash[:8]}'
        profile = run / 'profile/agent'
        profile.mkdir(parents=True)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        server.log_path = run / 'provider-requests.jsonl'
        server.record_lock = threading.Lock()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        models = dict(providers={'p5-local': dict(api='openai-completions', baseUrl=f'http://127.0.0.1:{server.server_port}/v1', auth='none', models=[dict(id='forward', contextWindow=4000000, maxTokens=1000000)])})
        (profile / 'models.yml').write_text(json.dumps(models))
        (profile / 'config.yml').write_text('modelRoles:\n  default: p5-local/forward\ntask:\n  isolation:\n    enabled: false\n  batch: false\n  structured: false\n  maxRecursionDepth: 1\n')
        agents = run / '.omp/agents'
        agents.mkdir(parents=True)
        (agents / 'p5-worker.md').write_text('---\nname: p5-worker\ndescription: Local forward-only acceptance worker\nmodel: p5-local/forward\nblocking: true\nstructured: false\ntools: []\nspawns: none\n---\nReturn the deterministic local provider reply.\n')
        environment = dict(os.environ, OMP_P5_NATIVE_EXECUTABLE=binary)
        try:
            with (run / 'checks.log').open('w') as log:
                result = subprocess.run([str(runner), '--website-captures', str(run)], env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            summary = json.loads((run / 'summary.json').read_text()) if (run / 'summary.json').exists() else dict(status='failed', version=version, error='See checks.log')
            summary.update(executable=binary, executable_sha256=binary_hash, version=version, returncode=result.returncode)
            if result.returncode:
                summary['status'] = 'failed'
            summaries.append(summary)
            print(version, summary['status'], len(summary.get('checks', [])), run, flush=True)
            if result.returncode:
                print((run / 'checks.log').read_text()[-5000:], flush=True)
            if summary['status'] != 'passed':
                break
        finally:
            server.shutdown()
            server.server_close()
    report = dict(date=datetime.now(ZoneInfo('Asia/Hong_Kong')).isoformat(), dylib_sha256=hashlib.sha256((code / 'OMP GUI Dev.debug.dylib').read_bytes()).hexdigest(),
                  runtimes=summaries, not_run=args.omp[len(summaries):])
    (output / 'matrix.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print('Matrix:', output / 'matrix.json', flush=True)
    raise SystemExit(0 if all(s['status'] == 'passed' for s in summaries) else 1)


if __name__ == '__main__':
    main()
