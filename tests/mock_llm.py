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

GO_NOTES = """<!doctype html><html><head><title>Go 1.27 Release Notes</title><script>x=1</script></head><body>
<nav>Docs menu</nav><main><h1>Go 1.27 Release Notes</h1>
<h2 id="introduction">Introduction to Go 1.27</h2><p>The latest Go release, version 1.27, arrives six months after Go 1.26.</p>
<h2 id="language">Changes to the language</h2><p>Go 1.27 adds generic type aliases with constraints and the new <code>for range</code> over funcs improvements.</p>
<h2 id="tools">Tools</h2><h3 id="go-command">Go command</h3><p>The go command now caches test results more aggressively.</p>
<h2 id="library">Standard library</h2><p>Several packages were added.</p>
<h3 id="uuid">New uuid package</h3><p>The new <code>uuid</code> package generates and parses UUIDs (UUIDv4 and UUIDv7).</p>
<pre>id := uuid.New()</pre>
<h3 id="json">New encoding/json/v2 package</h3><p>encoding/json/v2 is a major revision of encoding/json.</p>
<h3 id="minor">Minor changes to the library</h3><h4>slices</h4><p>The new function slices.Chunk splits a slice.</p>
</main><footer>Copyright</footer></body></html>"""

PY_NOTES = """<html><body><div role="main"><h1>What's new in Python 3.14<a class="headerlink" href="#x">¶</a></h1>
<h2>Summary – Release highlights<a href="#s">¶</a></h2><p>Python 3.14 is the latest stable release.</p>
<h2>New features</h2><h3><a href="https://peps.python.org/pep-0649/">PEP 649</a>: Deferred evaluation of annotations¶</h3>
<p>Annotations are now evaluated lazily.</p></div></body></html>"""

RUST_RELEASES = """Version 1.92.0 (2025-12-11)
==========================

Language
--------
- Feature from the future

Version 1.91.0 (2025-10-30)
==========================

Language
--------
- Lint against dangling raw pointers from local variables

Stabilized APIs
---------------
- `Path::file_prefix`
- `<i8>::strict_add`

Cargo
-----
- Stabilize build.build-dir

Version 1.90.0 (2025-09-18)
==========================

Language
--------
- OLD_1_90_FEATURE
"""

CPP23 = """<html><body><div id="content"><h1>C++23</h1><h2>New language features</h2><p>Deducing this, if consteval.</p>
<h2>New library features</h2><h3>New headers</h3><p>&lt;expected&gt;, &lt;print&gt;, &lt;flat_map&gt;</p></div></body></html>"""


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
    if "[Aqua AI harness]" in text and "check_project" in text:
        return {"calls": [("check_project", {"mode": "vet"})]}
    if "make-go" in text:
        return {"calls": [("write_file", {"path": "extra.go", "content": "package main\n"})]}
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
        if not self.path.startswith(("/api/", "/v1/", "/requests")):
            REQUESTS.append({"path": self.path, "method": "GET"})
        if self.path == "/doc/go1.27":
            return self._send(200, GO_NOTES, "text/html")
        if self.path.startswith("/slowdoc/"):
            time.sleep(3)
            return self._send(200, GO_NOTES, "text/html")
        if self.path == "/py/whatsnew/3.14.html":
            return self._send(200, PY_NOTES, "text/html")
        if self.path == "/rust/RELEASES.md":
            return self._send(200, RUST_RELEASES, "text/markdown")
        if self.path == "/cpp/23":
            return self._send(200, CPP23, "text/html")
        if self.path.startswith("/npm/express@4.21.2/README.md"):
            return self._send(200, "# Express 4.21.2\n\nFast web framework.\n\n## Routing\n\napp.get(path, handler) defines a route.\n", "text/markdown")
        if self.path.startswith("/pypi/fastapi/0.115.6/json"):
            return self._send(200, json.dumps({"info": {"name": "fastapi", "version": "0.115.6", "summary": "FastAPI framework",
                "requires_python": ">=3.8", "description": "# FastAPI\n\n## Dependencies\n\nUse Depends() to declare dependencies."}}))
        if self.path.startswith("/pypi/fastapi/json"):
            return self._send(200, json.dumps({"info": {"name": "fastapi", "version": "9.9.9", "summary": "latest", "description": "# FastAPI latest"}}))
        if self.path.startswith("/crates/tokio/1.40.0/readme"):
            return self._send(200, "<html><body><h1>Tokio</h1><h2>Example</h2><p>#[tokio::main] async fn main()</p></body></html>", "text/html")
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
        # Как настоящий Ollama: properties должен быть объектом, иначе 400
        for t in body.get("tools", []):
            props = t.get("function", {}).get("parameters", {}).get("properties")
            if props is not None and not isinstance(props, dict):
                return self._send(400, json.dumps({"error": "Value looks like object, but can't find closing '}' symbol"}))
        msgs = body.get("messages", [])
        REQUESTS.append({"path": self.path, "model": body.get("model"), "tools": [t["function"]["name"] for t in body.get("tools", [])],
                         "num_ctx": (body.get("options") or {}).get("num_ctx"), "n": len(msgs),
                         "roles": [m["role"] for m in msgs],
                         "system": msgs[0].get("content", "") if msgs and msgs[0].get("role") == "system" else ""})
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
