#!/usr/bin/env python3
"""Мок-сервер для тестов Aqua AI: имитирует Ollama (/api/chat) и OpenAI-совместимый API
(/v1/chat/completions) со стримингом и вызовами инструментов, а также веб-страницы и поиск.

Поведение определяется последним сообщением:
  user + "make-file"  → tool_call write_file notes/hello.md
  user + "edit-file"  → tool_call edit_file
  user + "two-tools"  → два tool_call подряд
  user + "fail-error" → ошибка провайдера
  user + "slow"       → медленный поток (для проверки отмены)
  user + "empty"      → пустой ответ
  tool                → итоговый текст «Готово: …»
  иначе               → обычный текстовый ответ
Печатает порт первой строкой.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<html><head><title>T</title><script>var x=1;</script><style>p{}</style></head>
<body><nav>MENU</nav><main><h1>Заголовок &amp; тест</h1><p>Первый <b>абзац</b> с <a href="https://example.com/x">ссылкой</a>.</p>
<ul><li>один</li><li>два</li></ul><pre>code()</pre>""" + ("<p>" + "текст " * 120 + "</p>") + """</main><footer>FOOTER</footer></body></html>"""

REQUESTS = []


def script(messages):
    last = messages[-1] if messages else {}
    role = last.get("role")
    text = last.get("content") or ""
    if role == "tool":
        return {"text": "Готово: " + text[:40]}
    if "fail-error" in text:
        return {"error": "boom"}
    if "empty" in text:
        return {"text": ""}
    if "slow" in text:
        return {"slow": True}
    if "make-file" in text:
        return {"calls": [("write_file", {"path": "notes/hello.md", "content": "# Hello\n\n- one\n"})]}
    if "edit-file" in text:
        return {"calls": [("edit_file", {"path": "notes/hello.md", "old_string": "one", "new_string": "ONE"})]}
    if "two-tools" in text:
        return {"calls": [("create_dir", {"path": "a/b"}), ("write_file", {"path": "a/b/c.txt", "content": "x"})]}
    return {"text": "Привет! Это тест."}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _line(self, s):
        self.wfile.write(s.encode())
        self.wfile.flush()

    def do_GET(self):
        if self.path.startswith("/api/tags"):
            return self._send(200, json.dumps({"models": [{"name": "mock:1b"}]}))
        if self.path.startswith("/v1/models"):
            return self._send(200, json.dumps({"data": [{"id": "mock-oai"}]}))
        if self.path.startswith("/page"):
            return self._send(200, PAGE, "text/html")
        if self.path.startswith("/plain"):
            return self._send(200, "plain text body", "text/plain")
        if self.path.startswith("/search"):
            return self._send(200, json.dumps({"results": [
                {"title": "Result One", "url": "https://one.example/", "content": "snippet one"},
                {"title": "Result Two", "url": "https://two.example/", "content": "snippet two"}]}))
        if self.path.startswith("/requests"):
            return self._send(200, json.dumps(REQUESTS))
        self._send(404, "{}")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        if self.path == "/api/chat":
            return self.ollama(body)
        if self.path == "/v1/chat/completions":
            return self.openai(body)
        self._send(404, "{}")

    def ollama(self, body):
        REQUESTS.append({"path": self.path, "model": body.get("model"), "tools": [t["function"]["name"] for t in body.get("tools", [])],
                         "num_ctx": (body.get("options") or {}).get("num_ctx"), "n": len(body.get("messages", [])),
                         "roles": [m["role"] for m in body.get("messages", [])]})
        s = script(body.get("messages", []))
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        if "error" in s:
            return self._line(json.dumps({"error": s["error"]}) + "\n")
        if s.get("slow"):
            for i in range(24):
                self._line(json.dumps({"message": {"role": "assistant", "content": f"tok{i} "}, "done": False}) + "\n")
                time.sleep(0.12)
            return self._line(json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n")
        for chunk in (["Прив", "ет! Это ", "тест."] if s.get("text") == "Привет! Это тест." else ([s["text"]] if s.get("text") else [])):
            self._line(json.dumps({"message": {"role": "assistant", "content": chunk}, "done": False}) + "\n")
        if "text" in s and s["text"] and s["text"] != "Привет! Это тест.":
            pass
        for name, args in s.get("calls", []):
            self._line(json.dumps({"message": {"role": "assistant", "content": "", "tool_calls": [
                {"function": {"name": name, "arguments": args}}]}, "done": False}) + "\n")
        self._line(json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}) + "\n")

    def openai(self, body):
        REQUESTS.append({"path": self.path, "model": body.get("model"), "tools": [t["function"]["name"] for t in body.get("tools", [])], "n": len(body.get("messages", []))})
        s = script(body.get("messages", []))
        if "error" in s:
            return self._send(400, json.dumps({"error": {"message": s["error"]}}))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def ev(delta, finish=None):
            self._line("data: " + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n")

        if s.get("slow"):
            for i in range(24):
                ev({"content": f"tok{i} "})
                time.sleep(0.12)
        elif s.get("text"):
            for chunk in [s["text"][:4], s["text"][4:]]:
                ev({"content": chunk})
        for i, (name, args) in enumerate(s.get("calls", [])):
            a = json.dumps(args)
            ev({"tool_calls": [{"index": i, "id": f"call_{i}", "type": "function", "function": {"name": name, "arguments": ""}}]})
            ev({"tool_calls": [{"index": i, "function": {"arguments": a[:7]}}]})
            ev({"tool_calls": [{"index": i, "function": {"arguments": a[7:]}}]})
        ev({}, "tool_calls" if s.get("calls") else "stop")
        self._line("data: [DONE]\n\n")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
