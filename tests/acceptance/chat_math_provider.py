"""Fixed-rate SSE math for the explicitly launched real-chat acceptance."""
from http.server import BaseHTTPRequestHandler
import json
import time
import uuid


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        users = [message for message in body.get("messages", []) if message.get("role") == "user"]
        content = users[-1].get("content", "") if users else ""
        streaming = "Q_MATH_STREAM" in str(content)
        with self.server.record_lock:
            with self.server.log_path.open("a") as log:
                log.write(json.dumps(dict(path=self.path, user=content, monotonic=time.monotonic()), ensure_ascii=False) + "\n")
        if streaming:
            reply = "行内公式与正文中心对齐：\n\n"
            for i in range(24):
                reply += (f"第 {i + 1} 段，中文 English 混排，$x_{{{i}}}^2+\\sqrt{{1+x^2}}$ 与 "
                          f"$\\frac{{a_{{{i}}}+b}}{{c+d}}$；公式透明背景，正文继续流式输出。\n\n")
            reply += ("$$\\begin{aligned} E &= mc^2 \\\\ F &= \\dv{p}{t} \\end{aligned}$$\n\n"
                      "化学 $\\ce{H2O}$、彩色 $x+\\color{blue}{y}$，末尾原生正文。MATH_STREAM_DONE")
            long = "+".join(f"a_{{{i}}}" for i in range(32))
            reply += f"\n\n超宽行内公式 ${long}=S$，后续正文按当前页面宽度继续换行。\n\n$$ {long}=S $$\n\n末尾普通公式 $E=mc^2$。"
        else:
            reply = "P5_REPLY\n\n" + "\n\n".join(
                f"历史段落 {i + 1}：原生中文与 English 正文，$x_{{{i}}}+\\sqrt{{1+x^2}}$；"
                "滚动阅读时保持当前内容位置，公式由共享 MathJax 离线渲染。" for i in range(55))
        base = dict(id="chat-math-" + uuid.uuid4().hex, object="chat.completion.chunk", created=int(time.time()), model="forward")
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunk_size = 12 if streaming else 4096
            started = time.monotonic()
            for index, offset in enumerate(range(0, len(reply), chunk_size)):
                if streaming:
                    time.sleep(max(0, started + index * 0.128 - time.monotonic()))
                frame = dict(base, choices=[dict(index=0, delta=dict(role="assistant", content=reply[offset:offset + chunk_size]), finish_reason=None)])
                self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
                self.wfile.flush()
            frame = dict(base, choices=[dict(index=0, delta={}, finish_reason="stop")],
                         usage=dict(prompt_tokens=64, completion_tokens=len(reply) // 2, total_tokens=64 + len(reply) // 2))
            self.wfile.write(("data: " + json.dumps(frame) + "\n\ndata: [DONE]\n\n").encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
