-- Тесты Aqua AI (собственный агентский харнес). Подключаются из tests/run.lua.
-- Сеть не нужна: модель имитирует tests/mock_llm.py (Ollama + OpenAI протоколы).
return function(T)
  local describe, it, eq, ok, wait, tmp, real = T.describe, T.it, T.eq, T.ok, T.wait, T.tmp, T.real
  local uv = vim.uv or vim.loop

  local config = require("aqua.ai.config")
  local provider = require("aqua.ai.provider")
  local tools = require("aqua.ai.tools")
  local sandbox = require("aqua.ai.tools.sandbox")
  local permissions = require("aqua.ai.permissions")
  local session_mod = require("aqua.ai.session")
  local web = require("aqua.ai.tools.web")
  local md = require("aqua.ai.tools.md")

  -- ── Мок-сервер модели ─────────────────────────────────────────────────────
  local have_python = vim.fn.executable("python3") == 1
  local port, host, server
  if have_python then
    server = vim.system({ "python3", vim.fn.stdpath("config") .. "/tests/mock_llm.py" }, {
      text = true,
      stdout = function(_, d)
        if d and not port then port = d:match("(%d+)") end
      end,
    })
    vim.wait(5000, function() return port ~= nil end, 20)
    host = "http://127.0.0.1:" .. tostring(port)
  end

  local proj = real(tmp) .. "/aiproj"
  vim.fn.mkdir(proj, "p")
  vim.fn.system({ "git", "init", "-q", proj })
  vim.fn.writefile({ "# Doc", "", "text" }, proj .. "/main.md")

  local function setup(extra)
    config.user = {}
    config.setup(vim.tbl_deep_extend("force", {
      profiles = {
        default = { provider = "ollama", host = host, model = "mock:1b" },
        oai = { provider = "openai", host = host, model = "mock-oai" },
      },
      permissions = { read = "allow", write = "allow", delete = "allow", web = "allow" },
      allow_private_web = true,
      search = { engine = "searxng", url = host },
    }, extra or {}))
    config.set_profile("default")
  end
  setup()

  local function ctx(extra_cfg, session)
    local _, cfg = config.profile()
    return { root = proj, cfg = vim.tbl_deep_extend("force", cfg, extra_cfg or {}), session = session }
  end

  --- Синхронный вызов инструмента: result, is_err, denied
  local function exec(name, args, c)
    local res
    tools.execute(name, args, c or ctx(), function(r, e, d) res = { r, e, d } end)
    vim.wait(8000, function() return res ~= nil end, 10)
    ok(res, "таймаут инструмента " .. name)
    return res[1], res[2], res[3]
  end

  local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
  end

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · провайдеры (разбор потока)", function()
    it("Ollama: текст приходит кусками, строка может обрываться посреди JSON", function()
      local got = {}
      local p = provider.new_parser("ollama", { on_text = function(s) got[#got + 1] = s end })
      p:feed('{"message":{"content":"Hel"},"done":false}\n{"mess')
      p:feed('age":{"content":"lo"},"done":false}\n{"message":{"content":""},"done":true}\n')
      local msg = p:finish()
      eq("Hello", msg.content)
      eq({ "Hel", "lo" }, got)
      ok(p.done)
    end)

    it("Ollama: вызов инструмента (аргументы — объект или строка)", function()
      local p = provider.new_parser("ollama")
      p:feed('{"message":{"content":"","tool_calls":[{"function":{"name":"read_file","arguments":{"path":"a.lua"}}}]},"done":false}\n')
      p:feed('{"message":{"content":"","tool_calls":[{"function":{"name":"grep","arguments":"{\\"pattern\\":\\"x\\"}"}}]},"done":true}\n')
      local msg = p:finish()
      eq(2, #msg.tool_calls)
      eq("read_file", msg.tool_calls[1].name)
      eq("a.lua", msg.tool_calls[1].args.path)
      eq("x", msg.tool_calls[2].args.pattern)
      ok(msg.tool_calls[1].id ~= msg.tool_calls[2].id, "уникальные id")
    end)

    it("Ollama: ошибка сервера", function()
      local p = provider.new_parser("ollama")
      p:feed('{"error":"model \'x\' not found"}\n')
      local msg, err = p:finish()
      eq(nil, msg)
      ok(err:find("not found", 1, true))
    end)

    it("OpenAI: SSE, аргументы инструмента приходят частями", function()
      local p = provider.new_parser("openai")
      p:feed('data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n')
      p:feed('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":""}}]}}]}\n\n')
      p:feed('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"pa"}}]}}]}\n\ndata: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"x\\"}"}}]}}]}\n\n')
      p:feed('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n')
      local msg = p:finish()
      eq("Hi", msg.content)
      eq("c1", msg.tool_calls[1].id)
      eq("x", msg.tool_calls[1].args.path)
    end)

    it("OpenAI: невалидный JSON аргументов помечается bad_args", function()
      local p = provider.new_parser("openai")
      p:feed('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"x","arguments":"{oops"}}]}}]}\n\ndata: [DONE]\n\n')
      local msg = p:finish()
      ok(msg.tool_calls[1].bad_args)
    end)

    it("OpenAI: ошибка без префикса data:", function()
      local p = provider.new_parser("openai")
      p:feed('{"error":{"message":"bad key"}}')
      local msg, err = p:finish()
      eq(nil, msg)
      eq("bad key", err)
    end)

    it("сериализация: пустые аргументы → {}, id вызовов сохраняются", function()
      local msgs = {
        { role = "assistant", content = "", tool_calls = { { id = "c1", name = "list_dir", args = {} } } },
        { role = "tool", tool_call_id = "c1", name = "list_dir", content = "ok" },
      }
      local o = provider.to_ollama(msgs)
      eq("{}", vim.json.encode(o[1].tool_calls[1]["function"].arguments))
      eq("list_dir", o[2].tool_name)
      local a = provider.to_openai(msgs)
      eq("{}", a[1].tool_calls[1]["function"].arguments)
      eq("c1", a[1].tool_calls[1].id)
      eq("c1", a[2].tool_call_id)
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  if have_python then
    describe("Aqua AI · провайдеры (сеть, curl → мок-сервер)", function()
      local function chat(profile_name, text, tool_list)
        local profile = select(1, config.profile())
        profile = vim.tbl_extend("force", profile, select(2, config.profile()).profiles[profile_name])
        local res = {}
        provider.chat(profile, { messages = { { role = "user", content = text } }, tools = tool_list }, {
          on_text = function(d) res.streamed = (res.streamed or "") .. d end,
          on_done = function(m) res.msg = m end,
          on_error = function(e) res.err = e end,
        })
        vim.wait(8000, function() return res.msg ~= nil or res.err ~= nil end, 10)
        return res
      end

      for _, name in ipairs({ "default", "oai" }) do
        it(name .. ": потоковый текстовый ответ", function()
          local r = chat(name, "hello")
          eq(nil, r.err)
          eq("Привет! Это тест.", r.msg.content)
          eq("Привет! Это тест.", r.streamed)
        end)

        it(name .. ": вызов инструмента", function()
          local r = chat(name, "make-file")
          eq(nil, r.err)
          eq("write_file", r.msg.tool_calls[1].name)
          eq("notes/hello.md", r.msg.tool_calls[1].args.path)
          eq("# Hello\n\n- one\n", r.msg.tool_calls[1].args.content)
        end)

        it(name .. ": ошибка провайдера доходит до пользователя", function()
          local r = chat(name, "fail-error")
          ok(r.err and r.err:find("boom", 1, true), tostring(r.err))
        end)
      end

      it("недоступный сервер → понятное сообщение", function()
        local res = {}
        provider.chat({ provider = "ollama", host = "http://127.0.0.1:1", model = "m" }, { messages = { { role = "user", content = "x" } } }, {
          on_done = function() res.done = true end,
          on_error = function(e) res.err = e end,
        })
        vim.wait(5000, function() return res.err ~= nil end, 10)
        ok(res.err and res.err:find("Не удалось подключиться", 1, true), tostring(res.err))
      end)

      it("список моделей: Ollama и OpenAI", function()
        local got
        provider.list_models({ provider = "ollama", host = host }, function(m) got = m end)
        vim.wait(3000, function() return got ~= nil end, 10)
        eq({ "mock:1b" }, got)
        got = nil
        provider.list_models({ provider = "openai", host = host }, function(m) got = m end)
        vim.wait(3000, function() return got ~= nil end, 10)
        eq({ "mock-oai" }, got)
      end)

      it("модели отправляются схемы всех инструментов и num_ctx", function()
        chat("default", "hello", provider.tool_schemas(tools.list))
        local out = vim.system({ "curl", "-s", host .. "/requests" }, { text = true }):wait().stdout
        local reqs = vim.json.decode(out)
        local last
        for i = #reqs, 1, -1 do
          if reqs[i].path == "/api/chat" then last = reqs[i] break end
        end
        for _, name in ipairs({ "read_file", "write_file", "edit_file", "create_dir", "move_path", "delete_path", "web_search", "web_fetch", "md_outline", "md_write_section" }) do
          ok(vim.tbl_contains(last.tools, name), "инструмент не отправлен: " .. name)
        end
        eq(16384, last.num_ctx)
      end)
    end)
  end

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · песочница путей", function()
    it("пути внутри проекта разрешаются", function()
      local abs, rel = sandbox.resolve(ctx(), "a/b.txt")
      eq(proj .. "/a/b.txt", abs)
      eq("a/b.txt", rel)
      eq(proj, (sandbox.resolve(ctx(), ".")))
      eq(proj, (sandbox.resolve(ctx(), nil)))
      eq(proj .. "/x", (sandbox.resolve(ctx(), "a/../x")))
    end)

    it("выход за пределы проекта запрещён (.., абсолютные пути, ~)", function()
      for _, p in ipairs({ "../x", "a/../../x", "/etc/passwd", "~/secret" }) do
        local abs, err = sandbox.resolve(ctx(), p)
        eq(nil, abs, p)
        ok(err:find("вне проекта", 1, true), p .. ": " .. tostring(err))
      end
    end)

    it("симлинк наружу запрещён", function()
      local outside = real(tmp) .. "/outside"
      vim.fn.mkdir(outside, "p")
      uv.fs_symlink(outside, proj .. "/escape")
      local abs, err = sandbox.resolve(ctx(), "escape/file.txt")
      eq(nil, abs)
      ok(err:find("симлинк", 1, true), tostring(err))
      os.remove(proj .. "/escape")
    end)

    it("запись в .git запрещена, чтение — можно", function()
      local abs, err = sandbox.resolve(ctx(), ".git/config", { write = true })
      eq(nil, abs)
      ok(err:find(".git", 1, true))
      ok(sandbox.resolve(ctx(), ".git/config"))
    end)

    it("allow_outside_root снимает ограничение", function()
      ok(sandbox.resolve(ctx({ allow_outside_root = true }), "/etc/hosts"))
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · файловые инструменты", function()
    it("write_file создаёт файл и вложенные папки", function()
      local r, err = exec("write_file", { path = "docs/new/file.txt", content = "a\nb\n" })
      eq(false, err)
      ok(r:find("Создан", 1, true), r)
      eq("a\nb\n", read(proj .. "/docs/new/file.txt"))
    end)

    it("write_file перезаписывает существующий", function()
      local r = exec("write_file", { path = "docs/new/file.txt", content = "z\n" })
      ok(r:find("Перезаписан", 1, true), r)
      eq("z\n", read(proj .. "/docs/new/file.txt"))
    end)

    it("read_file: нумерация, диапазон, ошибки, числа-строки", function()
      exec("write_file", { path = "r.txt", content = "l1\nl2\nl3\nl4\n" })
      local r = exec("read_file", { path = "r.txt" })
      ok(r:find("1\tl1", 1, true) and r:find("4\tl4", 1, true), r)
      r = exec("read_file", { path = "r.txt", start_line = "2", end_line = 3 }) -- "2" строкой приводится к числу
      ok(r:find("2\tl2", 1, true) and r:find("3\tl3", 1, true) and not r:find("l1", 1, true) and not r:find("l4", 1, true), r)
      local _, e = exec("read_file", { path = "нет.txt" })
      ok(e, "ошибка для отсутствующего файла")
      local _, e2 = exec("read_file", {})
      ok(e2, "нет обязательного параметра")
    end)

    it("read_file не читает бинарные файлы", function()
      local f = io.open(proj .. "/bin.dat", "wb")
      f:write("abc\0def")
      f:close()
      local r, e = exec("read_file", { path = "bin.dat" })
      ok(e and r:find("Бинарный", 1, true), r)
    end)

    it("edit_file: точная замена", function()
      exec("write_file", { path = "e.txt", content = "alpha\nbeta\ngamma\n" })
      local r, e = exec("edit_file", { path = "e.txt", old_string = "beta", new_string = "BETA" })
      eq(false, e)
      eq("alpha\nBETA\ngamma\n", read(proj .. "/e.txt"))
    end)

    it("edit_file: не найдено / неоднозначно / replace_all", function()
      exec("write_file", { path = "e2.txt", content = "x\nx\ny\n" })
      local r, e = exec("edit_file", { path = "e2.txt", old_string = "zzz", new_string = "q" })
      ok(e and r:find("не найден", 1, true), r)
      r, e = exec("edit_file", { path = "e2.txt", old_string = "x", new_string = "q" })
      ok(e and r:find("2 раз", 1, true), r)
      eq("x\nx\ny\n", read(proj .. "/e2.txt"), "файл не изменён при ошибке")
      r, e = exec("edit_file", { path = "e2.txt", old_string = "x", new_string = "q", replace_all = "true" })
      eq(false, e)
      eq("q\nq\ny\n", read(proj .. "/e2.txt"))
    end)

    it("edit_file: спецсимволы Lua-шаблонов не ломают замену", function()
      exec("write_file", { path = "e3.txt", content = "a%1(b) [x]\n" })
      local _, e = exec("edit_file", { path = "e3.txt", old_string = "%1(b) [x]", new_string = "%2$&" })
      eq(false, e)
      eq("a%2$&\n", read(proj .. "/e3.txt"))
    end)

    it("не перезаписывает файл с несохранёнными изменениями в Neovim", function()
      exec("write_file", { path = "buf.txt", content = "orig\n" })
      vim.cmd.edit(proj .. "/buf.txt")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "my unsaved work" })
      local r, e = exec("write_file", { path = "buf.txt", content = "ai\n" })
      ok(e and r:find("несохранённ", 1, true), r)
      eq("orig\n", read(proj .. "/buf.txt"))
      vim.cmd("bwipeout!")
    end)

    it("после записи открытый (несохранённый-нет) буфер перечитывается", function()
      vim.cmd.edit(proj .. "/buf.txt")
      local b = vim.api.nvim_get_current_buf()
      exec("write_file", { path = "buf.txt", content = "fresh\n" })
      vim.wait(500, function() return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == "fresh" end, 20)
      eq("fresh", vim.api.nvim_buf_get_lines(b, 0, 1, false)[1])
      vim.cmd("bwipeout!")
    end)

    it("create_dir / move_path", function()
      local r, e = exec("create_dir", { path = "m/n" })
      eq(false, e)
      eq(1, vim.fn.isdirectory(proj .. "/m/n"))
      exec("write_file", { path = "m/f.txt", content = "1" })
      r, e = exec("move_path", { from = "m/f.txt", to = "m/n/g.txt" })
      eq(false, e)
      eq("1", read(proj .. "/m/n/g.txt"))
      eq(0, vim.fn.filereadable(proj .. "/m/f.txt"))
      r, e = exec("move_path", { from = "m/n/g.txt", to = "e.txt" })
      ok(e and r:find("уже существует", 1, true), "не перезаписывает существующее: " .. r)
    end)

    it("delete_path переносит в корзину (восстановимо), корень удалять нельзя", function()
      exec("write_file", { path = "del/x.txt", content = "keep me" })
      local r, e = exec("delete_path", { path = "del" })
      eq(false, e)
      eq(0, vim.fn.isdirectory(proj .. "/del"))
      local trash = r:match("корзине: (%S-)%)")
      ok(trash and vim.fn.filereadable(trash .. "/x.txt") == 1, "копия в корзине: " .. r)
      local _, e2 = exec("delete_path", { path = "." })
      ok(e2, "корень проекта защищён")
    end)

    it("list_dir / find_files / grep", function()
      exec("write_file", { path = "t/one.lua", content = "local needle = 1\n" })
      exec("write_file", { path = "t/sub/two.md", content = "# n\n" })
      local r = exec("list_dir", { path = "t", depth = 2 })
      ok(r:find("one.lua", 1, true) and r:find("sub/", 1, true) and r:find("two.md", 1, true), r)
      r = exec("find_files", { pattern = "*.md" })
      ok(r:find("t/sub/two.md", 1, true), r)
      r = exec("find_files", { pattern = "t/**/*.lua" })
      ok(r:find("t/one.lua", 1, true), r)
      r = exec("grep", { pattern = "needle", glob = "*.lua" })
      ok(r:find("t/one.lua:1:", 1, true), r)
      r = exec("grep", { pattern = "no_such_thing_zzz" })
      ok(r:find("нет", 1, true), r)
      ok(not r:find(proj, 1, true))
    end)

    it("open_in_editor открывает файл в окне редактора", function()
      vim.cmd("only")
      exec("open_in_editor", { path = "t/one.lua", line = 1 })
      eq(proj .. "/t/one.lua", real(vim.api.nvim_buf_get_name(0)))
    end)

    it("неизвестный инструмент и неверные аргументы дают понятную ошибку", function()
      local r, e = exec("rm_rf", {})
      ok(e and r:find("Неизвестный инструмент", 1, true) and r:find("read_file", 1, true), r)
      r, e = exec("read_file", "строка вместо объекта")
      ok(e, "аргументы не таблица")
    end)

    it("пользовательский инструмент регистрируется и выполняется", function()
      tools.register({
        name = "echo_test",
        category = "read",
        description = "echo",
        parameters = { type = "object", properties = { text = { type = "string" } }, required = { "text" } },
        run = function(a, _, done) done("echo:" .. a.text) end,
      })
      eq("echo:hi", (exec("echo_test", { text = "hi" })))
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · Markdown", function()
    local doc = table.concat({
      "# Title", "", "Intro text.", "", "## Install", "", "Step 1.", "", "### Sub", "", "Sub text.", "",
      "## Usage", "", "```bash", "# not a heading", "```", "", "Use it.", "",
    }, "\n")

    it("md_outline: структура с номерами строк, блоки кода игнорируются", function()
      exec("write_file", { path = "doc.md", content = doc })
      local r = exec("md_outline", { path = "doc.md" })
      ok(r:find("L1 # Title", 1, true) and r:find("L5   ## Install", 1, true) and r:find("L9     ### Sub", 1, true) and r:find("Usage", 1, true), r)
      ok(not r:find("not a heading", 1, true), r)
    end)

    it("md_read_section: с подразделами и без", function()
      local r = exec("md_read_section", { path = "doc.md", heading = "Install" })
      ok(r:find("Step 1.", 1, true) and r:find("Sub text.", 1, true) and not r:find("Use it.", 1, true), r)
      r = exec("md_read_section", { path = "doc.md", heading = "## install", include_subsections = false })
      ok(r:find("Step 1.", 1, true) and not r:find("Sub text.", 1, true), r)
      local _, e = exec("md_read_section", { path = "doc.md", heading = "Нет такого" })
      ok(e)
    end)

    it("md_write_section replace: меняет текст раздела, подразделы остаются", function()
      local r, e = exec("md_write_section", { path = "doc.md", heading = "Install", content = "New install text." })
      eq(false, e)
      local s = read(proj .. "/doc.md")
      ok(s:find("## Install\n\nNew install text.\n\n### Sub\n\nSub text.", 1, true), s)
      ok(not s:find("Step 1.", 1, true))
      ok(s:find("Use it.", 1, true) and s:find("# Title", 1, true), "остальное цело")
    end)

    it("md_write_section append / prepend", function()
      exec("md_write_section", { path = "doc.md", heading = "Usage", content = "Appended.", mode = "append" })
      exec("md_write_section", { path = "doc.md", heading = "Usage", content = "First line.", mode = "prepend" })
      local s = read(proj .. "/doc.md")
      local a, b, c = s:find("First line.", 1, true), s:find("Use it.", 1, true), s:find("Appended.", 1, true)
      ok(a and b and c and a < b and b < c, s)
      ok(s:find("# not a heading", 1, true), "код внутри раздела сохранён")
    end)

    it("md_write_section append: пункт продолжает список без пустой строки", function()
      exec("write_file", { path = "list.md", content = "# T\n\n## Планы\n\n- один\n- два\n\n## Конец\n\nтекст\n" })
      exec("md_write_section", { path = "list.md", heading = "Планы", content = "- три", mode = "append" })
      exec("md_write_section", { path = "list.md", heading = "Планы", content = "- ноль", mode = "prepend" })
      eq("# T\n\n## Планы\n\n- ноль\n- один\n- два\n- три\n\n## Конец\n\nтекст\n", read(proj .. "/list.md"))
    end)

    it("md_write_section создаёт новый раздел в конце / новый файл", function()
      exec("md_write_section", { path = "doc.md", heading = "FAQ", content = "Q&A", level = 3 })
      local s = read(proj .. "/doc.md")
      ok(s:find("\n### FAQ\n\nQ&A\n$"), s)
      exec("md_write_section", { path = "fresh/notes.md", heading = "Идеи", content = "- одна" })
      eq("## Идеи\n\n- одна\n", read(proj .. "/fresh/notes.md"))
    end)

    it("предпросмотр для подтверждения содержит diff", function()
      local info
      permissions.handler = function(_, i, cb) info = i cb("no") end
      local _, _, denied = exec("md_write_section", { path = "doc.md", heading = "Title", content = "changed" }, ctx({ permissions = { write = "ask" } }))
      permissions.handler = nil
      ok(denied)
      ok(info.diff:find("+changed", 1, true), info.diff)
    end)

    it("headings(): уровни, заголовки в ~~~ блоках тоже игнорируются", function()
      local h = md.headings({ "# A", "~~~", "# no", "~~~", "###### F", "####### seven" })
      eq(2, #h)
      eq(6, h[2].level)
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · права и подтверждения", function()
    local function ask_ctx(session)
      return ctx({ permissions = { read = "allow", write = "ask", delete = "ask", web = "ask" } }, session)
    end

    it("отклонение: файл не создаётся, модель получает понятный ответ", function()
      local info
      permissions.handler = function(cat, i, cb) info = { cat = cat, i = i } cb("no") end
      local r, e, denied = exec("write_file", { path = "nope.txt", content = "hello" }, ask_ctx())
      permissions.handler = nil
      ok(e and denied, "denied")
      ok(r:find("отклонил", 1, true), r)
      eq("write", info.cat)
      ok(info.i.title:find("nope.txt", 1, true) and info.i.diff:find("+hello", 1, true), vim.inspect(info.i))
      eq(0, vim.fn.filereadable(proj .. "/nope.txt"))
    end)

    it("разрешение выполняет действие; чтение подтверждений не требует", function()
      local asked = 0
      permissions.handler = function(_, _, cb) asked = asked + 1 cb("yes") end
      exec("write_file", { path = "yes.txt", content = "1" }, ask_ctx())
      exec("read_file", { path = "yes.txt" }, ask_ctx())
      permissions.handler = nil
      eq(1, asked)
      eq(1, vim.fn.filereadable(proj .. "/yes.txt"))
    end)

    it("«всегда»: дальше без вопросов в этой категории, другие категории — по-прежнему с вопросом", function()
      local session = { allowed = {}, yolo = false, emit_status = function() end }
      local asked = {}
      permissions.handler = function(cat, _, cb) asked[#asked + 1] = cat cb("always") end
      exec("write_file", { path = "al1.txt", content = "1" }, ask_ctx(session))
      exec("write_file", { path = "al2.txt", content = "2" }, ask_ctx(session))
      exec("delete_path", { path = "al2.txt" }, ask_ctx(session))
      permissions.handler = nil
      eq({ "write", "delete" }, asked)
    end)

    it("YOLO разрешает всё без вопросов", function()
      local session = { allowed = {}, yolo = true, emit_status = function() end }
      permissions.handler = function() error("не должно спрашивать") end
      local _, e = exec("write_file", { path = "yolo.txt", content = "1" }, ask_ctx(session))
      permissions.handler = nil
      eq(false, e)
    end)

    it("deny: инструмент скрыт от модели и не выполняется", function()
      local c = ctx({ permissions = { web = "deny", delete = "deny" } })
      local names = vim.tbl_map(function(t) return t.name end, tools.available(c.cfg))
      ok(not vim.tbl_contains(names, "web_search") and not vim.tbl_contains(names, "delete_path"))
      ok(vim.tbl_contains(names, "read_file"))
      local r, e, denied = exec("delete_path", { path = "yes.txt" }, c)
      ok(e and denied and r:find("запрещено настройками", 1, true), r)
      eq(1, vim.fn.filereadable(proj .. "/yes.txt"))
    end)

    it("окно подтверждения: показывает diff, y — разрешает, n — отклоняет", function()
      local function run(key)
        local res
        tools.execute("write_file", { path = "ui_" .. key .. ".txt", content = "line" }, ask_ctx(), function(r, e, d) res = { r, e, d } end)
        permissions.last_key = 0 -- пользователь не печатает
        wait(2000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end, "окно подтверждения")
        vim.wait(350) -- короткая пауза, в течение которой клавиши игнорируются
        local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
        ok(text:find("ui_" .. key .. ".txt", 1, true) and text:find("+line", 1, true) and text:find("[y]", 1, true), text)
        vim.fn.maparg(key, "n", false, true).callback()
        vim.wait(2000, function() return res ~= nil end, 10)
        eq(0, vim.api.nvim_win_get_config(0).relative == "" and 0 or 1, "окно закрыто")
        return res
      end
      local res = run("y")
      eq(false, res[2])
      eq(1, vim.fn.filereadable(proj .. "/ui_y.txt"))
      res = run("n")
      ok(res[2] and res[3])
      eq(0, vim.fn.filereadable(proj .. "/ui_n.txt"))
    end)
  end)

  describe("Aqua AI · подтверждения, пока вы печатаете", function()
    local function open_prompt(name)
      local res
      tools.execute("write_file", { path = name, content = "x" }, ctx({ permissions = { write = "ask" } }), function(r, e, d) res = { r, e, d } end)
      wait(2000, function() return vim.api.nvim_win_get_config(0).relative ~= "" end, "окно подтверждения")
      return function() return res end
    end
    local function press(key)
      vim.fn.maparg(key, "n", false, true).callback()
    end

    it("пока вы печатаете, обычные y / a / Enter ничего не разрешают", function()
      permissions.last_key = vim.uv.now() -- только что нажимали клавиши
      local result = open_prompt("typing1.txt")
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      ok(text:find("Ctrl-Y", 1, true) and text:find("печатаете", 1, true), text)
      vim.wait(400)
      press("y")
      press("a")
      press("<CR>")
      eq(nil, result(), "случайные буквы не разрешили действие")
      eq(0, vim.fn.filereadable(proj .. "/typing1.txt"))
      press("<C-y>")
      vim.wait(2000, function() return result() ~= nil end, 10)
      eq(false, result()[2])
      eq(1, vim.fn.filereadable(proj .. "/typing1.txt"))
    end)

    it("отклонить можно всегда; Ctrl-A разрешает категорию", function()
      permissions.last_key = vim.uv.now()
      local result = open_prompt("typing2.txt")
      press("n")
      vim.wait(2000, function() return result() ~= nil end, 10)
      ok(result()[3], "отклонено")
      eq(0, vim.fn.filereadable(proj .. "/typing2.txt"))
    end)

    it("после паузы в наборе окно «вооружается» и работают обычные клавиши", function()
      permissions.last_key = vim.uv.now() - 100
      local result = open_prompt("typing3.txt")
      press("y")
      eq(nil, result(), "ещё печатаете — y игнорируется")
      vim.wait(2800, function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("[y] разрешить", 1, true) ~= nil end, 10)
      press("y")
      vim.wait(2000, function() return result() ~= nil end, 10)
      eq(false, result()[2])
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · интернет", function()
    it("html_to_text: заголовки, ссылки, списки; скрипты и навигация вырезаются", function()
      local t = web.html_to_text("<html><head><title>x</title><script>var a=1;</script></head><body><nav>MENU</nav><main>"
        .. ("<p>filler</p>"):rep(60)
        .. "<h2>Заголовок &amp; тест</h2><p>Текст <a href=\"https://e.com/x\">ссылка</a></p><ul><li>один</li><li>два</li></ul></main><footer>FOOT</footer></body></html>")
      ok(t:find("## Заголовок & тест", 1, true), t)
      ok(t:find("[ссылка](https://e.com/x)", 1, true), t)
      ok(t:find("- один", 1, true) and t:find("- два", 1, true), t)
      ok(not t:find("MENU") and not t:find("FOOT") and not t:find("var a"), t)
    end)

    it("check_url: локальные адреса блокируются по умолчанию", function()
      local cfg = { allow_private_web = false }
      for _, u in ipairs({ "http://localhost:8080/", "http://127.0.0.1/x", "http://10.0.0.5/", "http://192.168.1.1/", "http://172.20.1.1/", "http://169.254.169.254/latest", "http://nas.local/", "http://[::1]/" }) do
        eq(false, (web.check_url(u, cfg)), u)
      end
      for _, u in ipairs({ "https://example.com/", "http://172.32.0.1/", "https://sub.domain.org/path?q=1" }) do
        eq(true, (web.check_url(u, cfg)), u)
      end
      eq(false, (web.check_url("file:///etc/passwd", cfg)))
      eq(false, (web.check_url("ftp://x.com", cfg)))
      eq(true, (web.check_url("http://localhost/", { allow_private_web = true })))
    end)

    it("разбор выдачи DuckDuckGo: ссылки-редиректы, сниппеты, реклама отбрасывается", function()
      local html = [[
        <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_provider=x">Ad</a>
        <a class="result__snippet" href="x">ad text</a>
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fneovim.io%2Fdoc%3Fa%3D1&amp;rut=abc">Neovim <b>docs</b></a>
        <a class="result__snippet" href="x">The <b>best</b> editor &amp; more</a>
        <a rel="nofollow" class="result__a" href="https://example.org/two">Two</a>
        <a class="result__snippet" href="x">second</a>]]
      local r = web.parse_ddg(html)
      eq(2, #r)
      eq("Neovim docs", r[1].title)
      eq("https://neovim.io/doc?a=1", r[1].url)
      eq("The best editor & more", r[1].snippet)
      eq("https://example.org/two", r[2].url)
    end)

    if have_python then
      it("web_search (SearXNG) возвращает результаты в маркере web_content", function()
        local r, e = exec("web_search", { query = "neovim" })
        eq(false, e)
        ok(r:find("<web_content", 1, true) and r:find("Result One", 1, true) and r:find("https://two.example/", 1, true) and r:find("snippet one", 1, true), r)
      end)

      it("web_fetch: страница → читаемый текст, лимит символов", function()
        local r, e = exec("web_fetch", { url = host .. "/page" })
        eq(false, e)
        ok(r:find("# Заголовок & тест", 1, true) and r:find("[ссылкой](https://example.com/x)", 1, true), r)
        ok(not r:find("MENU", 1, true) and not r:find("var x", 1, true))
        r = exec("web_fetch", { url = host .. "/page", max_chars = 600 })
        ok(r:find("обрезан", 1, true), "обрезка")
        r = exec("web_fetch", { url = host .. "/plain" })
        ok(r:find("plain text body", 1, true), r)
      end)

      it("web_fetch к localhost запрещён, если не разрешено в настройках", function()
        local r, e = exec("web_fetch", { url = host .. "/page" }, ctx({ allow_private_web = false }))
        ok(e and r:find("локальным", 1, true), r)
      end)
    end
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Aqua AI · контекст", function()
    it("trim: сжимает старые результаты инструментов, оставляет последний запрос", function()
      local msgs = { { role = "user", content = "q1" } }
      for i = 1, 8 do
        msgs[#msgs + 1] = { role = "assistant", content = "", tool_calls = { { id = "c" .. i, name = "read_file", args = { path = "f" } } } }
        msgs[#msgs + 1] = { role = "tool", tool_call_id = "c" .. i, name = "read_file", content = ("x"):rep(5000) }
      end
      msgs[#msgs + 1] = { role = "user", content = "последний вопрос" }
      local out = session_mod.trim(msgs, 12000)
      ok(#out >= 1 and out[#out].content == "последний вопрос")
      local total = 0
      for _, m in ipairs(out) do total = total + #(m.content or "") end
      ok(total <= 12000 + 1000, "уложились в бюджет: " .. total)
      ok(out[3].content:find("опущен", 1, true) or out[2].role == "user", "старый вывод сжат или оборот отброшен")
      local intact = session_mod.trim(msgs, 1e9)
      eq(#msgs, #intact)
    end)

    it("системный промпт: корень проекта, правила и проектные инструкции", function()
      vim.fn.writefile({ "Always answer like a pirate." }, proj .. "/AQUA.md")
      local p = session_mod.system_prompt(proj, select(2, config.profile()))
      ok(p:find(proj, 1, true) and p:find("untrusted", 1, true) and p:find("Always answer like a pirate.", 1, true), p)
      os.remove(proj .. "/AQUA.md")
    end)

    it("профили: модель и профиль запоминаются между запусками", function()
      config.set_model("default", "other:7b")
      eq("other:7b", (config.profile()).model)
      config.set_profile("oai")
      local p = config.profile()
      eq("openai", p.provider)
      eq("mock-oai", p.model)
      config.set_profile("default")
      config.set_model("default", "mock:1b")
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  if have_python then
    describe("Aqua AI · цикл агента (сессия ↔ модель ↔ инструменты)", function()
      local function names(events)
        return vim.tbl_map(function(e) return e[1] end, events)
      end

      local function fresh(profile_name)
        setup()
        config.set_profile(profile_name or "default")
        session_mod.sessions[proj] = nil
        local s = session_mod.get(proj)
        s:reset()
        local events = {}
        s.cb = function(ev, ...) events[#events + 1] = { ev, ... } end
        return s, events
      end

      local function ask(s, events, text)
        local ok_, err = s:send(text)
        ok(ok_, tostring(err))
        wait(10000, function()
          for _, e in ipairs(events) do if e[1] == "done" then return true end end
        end, "завершение запроса")
      end

      local function collect(events, ev)
        local out = {}
        for _, e in ipairs(events) do if e[1] == ev then out[#out + 1] = e end end
        return out
      end

      for _, pname in ipairs({ "default", "oai" }) do
        it(pname .. ": обычный ответ стримится в события", function()
          local s, events = fresh(pname)
          ask(s, events, "привет")
          local text = table.concat(vim.tbl_map(function(e) return e[2] end, collect(events, "text")))
          eq("Привет! Это тест.", text)
          local seq = names(events)
          eq("user", seq[1])
          ok(vim.tbl_contains(seq, "assistant_start") and vim.tbl_contains(seq, "assistant_end"))
          eq("done", seq[#seq])
          eq(false, events[#events][2])
          eq({ "user", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages))
          eq(false, s.running)
        end)

        it(pname .. ": модель создаёт файл через инструмент и отвечает по результату", function()
          local s, events = fresh(pname)
          ask(s, events, "make-file please")
          eq("# Hello\n\n- one\n", read(proj .. "/notes/hello.md"))
          local ts, te = collect(events, "tool_start")[1], collect(events, "tool_end")[1]
          eq("write_file", ts[2].name)
          eq("notes/hello.md", ts[3])
          eq("write", ts[4])
          eq(false, te[4], "без ошибки")
          eq({ "user", "assistant", "tool", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages))
          ok(s.messages[4].content:find("Готово", 1, true), s.messages[4].content)
          eq(s.messages[2].tool_calls[1].id, s.messages[3].tool_call_id, "результат привязан к вызову")
          os.remove(proj .. "/notes/hello.md")
        end)
      end

      it("несколько вызовов подряд выполняются по порядку", function()
        local s, events = fresh()
        ask(s, events, "two-tools")
        eq(1, vim.fn.isdirectory(proj .. "/a/b"))
        eq("x", read(proj .. "/a/b/c.txt"))
        eq(2, #collect(events, "tool_end"))
        eq({ "user", "assistant", "tool", "tool", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages))
      end)

      it("диалог из нескольких запросов: edit_file по созданному файлу", function()
        local s, events = fresh()
        ask(s, events, "make-file")
        events = {}
        s.cb = function(ev, ...) events[#events + 1] = { ev, ... } end
        ask(s, events, "edit-file")
        eq("# Hello\n\n- ONE\n", read(proj .. "/notes/hello.md"))
        eq(8, #s.messages)
        os.remove(proj .. "/notes/hello.md")
      end)

      it("отказ пользователя: файла нет, модель узнаёт об отказе", function()
        local s, events = fresh()
        setup({ permissions = { write = "ask" } })
        permissions.handler = function(_, _, cb) cb("no") end
        ask(s, events, "make-file")
        permissions.handler = nil
        eq(0, vim.fn.filereadable(proj .. "/notes/hello.md"))
        local te = collect(events, "tool_end")[1]
        ok(te[4] and te[5], "ошибка + denied")
        ok(s.messages[3].content:find("отклонил", 1, true), s.messages[3].content)
        setup()
      end)

      it("ошибка провайдера: событие error, сессия снова свободна", function()
        local s, events = fresh()
        ask(s, events, "fail-error")
        local err = collect(events, "error")[1]
        ok(err and err[2]:find("boom", 1, true), vim.inspect(events))
        eq(false, s.running)
        ok(s:send("ещё раз"), "после ошибки можно писать снова")
        wait(5000, function() return not s.running end)
      end)

      it("пустой ответ модели объясняется пользователю", function()
        local s, events = fresh()
        ask(s, events, "empty")
        local err = collect(events, "error")[1]
        ok(err and err[2]:find("пустой", 1, true), vim.inspect(err))
      end)

      it("прерывание во время генерации (Ctrl-C)", function()
        local s, events = fresh()
        s:send("slow please")
        wait(5000, function() return #collect(events, "text") >= 2 end, "поток начался")
        s:cancel()
        eq(false, s.running)
        local done = collect(events, "done")
        eq(true, done[#done][2], "done(cancelled=true)")
        local n = #events
        vim.wait(700)
        eq(n, #events, "после отмены события не приходят")
        ok(s:send("привет"), "после отмены можно писать снова")
        wait(5000, function() return not s.running end)
      end)

      it("сообщение, отправленное во время ответа, встаёт в очередь и обрабатывается следом", function()
        local s, events = fresh()
        s:send("slow please")
        wait(5000, function() return #collect(events, "text") >= 1 end, "поток начался")
        local sent, how = s:send("второй вопрос")
        eq(true, sent)
        eq("queued", how)
        eq({ "второй вопрос" }, s.queue)
        ok(#collect(events, "queue") >= 1, "событие queue")
        wait(15000, function() return #collect(events, "done") >= 1 end, "оба запроса обработаны")
        eq(0, #s.queue)
        eq({ "user", "assistant", "user", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages))
        eq("второй вопрос", s.messages[3].content)
        eq("Привет! Это тест.", s.messages[4].content)
        eq(false, s.running)
      end)

      it("очередь подхватывается между вызовами инструментов (можно перенаправить агента)", function()
        local s, events = fresh()
        setup({ permissions = { write = "ask" } })
        local release
        permissions.handler = function(_, _, cb) release = cb end
        s:send("make-file")
        wait(5000, function() return release ~= nil end, "ждёт подтверждения")
        ok(s:send("уточнение"), "можно писать, пока ждём подтверждения")
        eq(1, #s.queue)
        release("yes")
        wait(10000, function() return #collect(events, "done") >= 1 end, "готово")
        permissions.handler = nil
        eq({ "user", "assistant", "tool", "user", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages))
        eq("уточнение", s.messages[4].content)
        eq(0, #s.queue)
        eq(1, vim.fn.filereadable(proj .. "/notes/hello.md"))
        setup()
        os.remove(proj .. "/notes/hello.md")
      end)

      it("Ctrl-C прерывает ответ и очищает очередь", function()
        local s, events = fresh()
        s:send("slow please")
        wait(5000, function() return #collect(events, "text") >= 1 end)
        s:send("a")
        s:send("b")
        eq(2, #s.queue)
        s:cancel()
        eq(0, #s.queue)
        eq(false, s.running)
        local done = collect(events, "done")
        eq(true, done[#done][2])
      end)

      it("ошибка модели очищает очередь и сообщает об этом", function()
        local s, events = fresh()
        s:send("fail-error")
        s:send("после ошибки") -- ставится в очередь до прихода ошибки
        eq(1, #s.queue)
        wait(5000, function() return #collect(events, "error") >= 1 end)
        local err = collect(events, "error")[1][2]
        ok(err:find("boom", 1, true) and err:find("Очередь очищена", 1, true), err)
        eq(0, #s.queue)
        eq(false, s.running)
      end)

      it("очередь ограничена 10 сообщениями", function()
        local s, events = fresh()
        s:send("slow please")
        for i = 1, 10 do ok(s:send("m" .. i)) end
        local sent, err = s:send("лишнее")
        eq(false, sent)
        ok(err:find("Очередь заполнена", 1, true), err)
        s:cancel()
      end)

      it("лимит шагов защищает от бесконечного цикла инструментов", function()
        local s, events = fresh()
        setup({ max_steps = 1 })
        ask(s, events, "make-file")
        local err = collect(events, "error")[1]
        ok(err and err[2]:find("лимит шагов", 1, true), vim.inspect(err))
        setup()
        os.remove(proj .. "/notes/hello.md")
      end)

      it("история сохраняется на диск и восстанавливается", function()
        local s, events = fresh()
        ask(s, events, "привет")
        session_mod.sessions[proj] = nil
        local again = session_mod.get(proj)
        eq(2, #again.messages)
        eq("привет", again.messages[1].content)
        again:reset()
        session_mod.sessions[proj] = nil
        eq(0, #session_mod.get(proj).messages, "после /new история пуста")
      end)

      it("модель не выбрана: единственная на сервере выбирается автоматически", function()
        local s, events = fresh()
        config.user = {}
        config.setup({ profiles = { auto = { provider = "ollama", host = host } }, profile = "auto", permissions = { write = "allow" } })
        config.set_profile("auto")
        config.set_model("auto", nil) -- состояние переживает запуски тестов
        eq(nil, (config.profile()).model)
        s.cb = function(ev, ...) events[#events + 1] = { ev, ... } end
        ask(s, events, "привет")
        eq("mock:1b", (config.profile()).model)
        eq("Привет! Это тест.", table.concat(vim.tbl_map(function(e) return e[2] end, collect(events, "text"))))
        config.set_model("auto", nil)
        setup()
      end)
    end)
  end

  -- ════════════════════════════════════════════════════════════════════════
  if have_python then
    describe("Aqua AI · интерфейс чата", function()
      local ai = require("aqua.ai")
      local ui = require("aqua.ai.ui")

      local function chat_text(st)
        return table.concat(vim.api.nvim_buf_get_lines(st.chat_buf, 0, -1, false), "\n")
      end

      local function wins()
        return vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
      end

      it("Space o: чат открывается справа, поле ввода под ним, в корне проекта", function()
        setup()
        session_mod.sessions[proj] = nil
        vim.cmd("only")
        vim.cmd.edit(proj .. "/main.md")
        local editor = vim.api.nvim_get_current_win()
        vim.fn.maparg(" o", "n", false, true).callback()
        local st = ui.visible_state()
        ok(st, "чат открыт")
        eq(proj, st.root)
        ok(vim.api.nvim_win_get_position(st.chat_win)[2] > vim.api.nvim_win_get_position(editor)[2], "справа от редактора")
        ok(vim.api.nvim_win_get_position(st.input_win)[1] > vim.api.nvim_win_get_position(st.chat_win)[1], "ввод под перепиской")
        eq(st.input_win, vim.api.nvim_get_current_win(), "фокус в поле ввода")
        local width = vim.api.nvim_win_get_width(st.chat_win)
        ok(math.abs(width - math.max(40, math.floor(vim.o.columns * 0.4))) <= 2, "ширина ~40% (мин. 40): " .. width)
        ok(chat_text(st):find("Aqua AI", 1, true) and chat_text(st):find("mock:1b", 1, true), chat_text(st))
        vim.g.statusline_winid = st.chat_win
        local bar = ui.winbar()
        ok(bar:find("mock:1b", 1, true) and bar:find("Aqua AI", 1, true), bar)
      end)

      it("отправка сообщения: переписка, вызов инструмента и ответ видны в буфере", function()
        local st = ui.visible_state()
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "make-file", "пожалуйста" })
        ok(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "в поле ввода есть <CR>")
        -- как у пользователя: поле ввода в режиме вставки, нажимается Enter
        local enter = vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg("<CR>", "i", false, true) end)
        ok(enter.buffer == 1 and enter.callback, "Enter в режиме вставки привязан к отправке")
        local newline = vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg("<C-j>", "i", false, true) end)
        ok(newline.buffer == 1 and newline.rhs == "<CR>" and newline.noremap == 1, "Ctrl-J — перенос строки")
        enter.callback()
        eq("", table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), ""), "поле ввода очищено")
        wait(10000, function() return not st.session.running and chat_text(st):find("Готово", 1, true) end, "ответ")
        local t = chat_text(st)
        ok(t:find("## 󰭹 Вы", 1, true) and t:find("make-file", 1, true), t)
        ok(t:find("`write_file` notes/hello.md", 1, true) and t:find("✓", 1, true), t)
        ok(t:find("## 🌊 Aqua · mock:1b", 1, true), t)
        eq("# Hello\n\n- one\n", read(proj .. "/notes/hello.md"))
        eq("idle", st.status)
      end)

      it("после отправки сразу можно писать и отправлять новое (очередь видна)", function()
        local st = ui.visible_state()
        st.session:reset()
        local function type_and_enter(text)
          vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, vim.split(text, "\n"))
          local m = vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg("<CR>", "i", false, true) end)
          m.callback()
        end
        type_and_enter("slow please")
        eq("", table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), ""), "поле ввода свободно сразу")
        wait(5000, function() return st.session.running and chat_text(st):find("slow please", 1, true) end)
        type_and_enter("следующий вопрос")
        eq("", table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), ""), "и для второго сообщения тоже")
        eq(1, #st.session.queue)
        local virt = vim.api.nvim_buf_get_extmarks(st.chat_buf, vim.api.nvim_create_namespace("aqua_ai_queue"), 0, -1, { details = true })
        ok(#virt == 1 and virt[1][4].virt_lines[1][1][1]:find("следующий вопрос", 1, true), "в чате видно ожидающее сообщение")
        vim.g.statusline_winid = st.input_win
        ok(ui.input_bar():find("в очереди: 1", 1, true), ui.input_bar())
        wait(15000, function() return not st.session.running and chat_text(st):find("## 󰭹 Вы\nследующий вопрос", 1, true) end, "обработана очередь")
        eq(0, #vim.api.nvim_buf_get_extmarks(st.chat_buf, vim.api.nvim_create_namespace("aqua_ai_queue"), 0, -1, {}), "очередь в чате пуста")
        ok(not ui.input_bar():find("в очереди", 1, true))
      end)

      it("Shift+Enter, Ctrl-J и «\\ + Enter» — новая строка; Enter — отправка", function()
        local st = ui.visible_state()
        for _, key in ipairs({ "<S-CR>", "<C-j>", "<M-CR>" }) do
          local m = vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg(key, "i", false, true) end)
          ok(m.buffer == 1 and m.rhs == "<CR>" and m.noremap == 1, key .. " → новая строка")
        end
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "первая\\" })
        vim.api.nvim_set_current_win(st.input_win)
        vim.api.nvim_win_set_cursor(st.input_win, { 1, 6 })
        ui.enter(st, true)
        eq({ "первая", "" }, vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\\ + Enter не отправляет")
        eq(0, #st.session.queue)
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "" })
      end)

      it("поле ввода растёт вместе с текстом и сжимается обратно", function()
        local st = ui.visible_state()
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "1", "2", "3", "4", "5", "6" })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = st.input_buf })
        eq(7, vim.api.nvim_win_get_height(st.input_win))
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "" })
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = st.input_buf })
        eq(4, vim.api.nvim_win_get_height(st.input_win))
      end)

      it("поле ввода — обычный текст, как в Claude Code: клавиши readline, без автоскобок", function()
        local st = ui.visible_state()
        local function imap(lhs)
          return vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg(lhs, "i", false, true) end)
        end
        for lhs, rhs in pairs({ ["<C-a>"] = "<Home>", ["<C-e>"] = "<End>", ["<C-b>"] = "<Left>", ["<C-f>"] = "<Right>", ["<C-k>"] = "<C-o>D" }) do
          local m = imap(lhs)
          ok(m.buffer == 1 and m.rhs == rhs, lhs .. " → " .. rhs .. " (" .. tostring(m.rhs) .. ")")
        end
        ok(imap("<Esc>").buffer == 1 and imap("<Esc>").callback, "Esc перехвачен (стоп / очистка)")
        eq(true, vim.b[st.input_buf].minipairs_disable, "автоскобки выключены")
        for _, ev in ipairs({ "InsertLeave", "BufEnter", "WinEnter" }) do
          eq(1, #vim.api.nvim_get_autocmds({ group = "aqua_ai_input_" .. st.input_buf, event = ev, buffer = st.input_buf }), ev .. ": вход в режим вставки")
        end
        eq(1, #vim.api.nvim_get_autocmds({ group = "aqua_ai_input_" .. st.input_buf, event = "InsertEnter", buffer = st.chat_buf }), "попытка печатать в переписке → перенос в ввод")
      end)

      it("Esc: останавливает ответ; когда модель молчит — второй Esc очищает ввод; Ctrl-C очищает сразу", function()
        local st = ui.visible_state()
        st.session:reset()
        local function text() return table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\n") end
        -- модель отвечает → Esc прерывает и очищает очередь
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "slow please" })
        ui.submit(st)
        wait(5000, function() return st.session.running and chat_text(st):find("slow please", 1, true) end)
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "в очередь" })
        ui.submit(st)
        eq(1, #st.session.queue)
        vim.g.statusline_winid = st.input_win
        ok(ui.input_bar():find("в очереди", 1, true))
        ui.esc(st)
        eq(false, st.session.running)
        eq(0, #st.session.queue)
        ok(chat_text(st):find("прервано", 1, true))
        -- модель молчит: первый Esc сохраняет набранное, второй очищает
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "черновик", "ответа" })
        ui.esc(st)
        eq("черновик\nответа", text())
        vim.g.statusline_winid = st.input_win -- redrawstatus перезаписывает эту переменную
        ok(ui.input_bar():find("Esc ещё раз", 1, true), ui.input_bar())
        ui.esc(st)
        eq("", text())
        ui.esc(st) -- пустой ввод: ничего не происходит
        eq("", text())
        -- Esc, нажатый давно — снова «первый»
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "x" })
        ui.esc(st)
        st.esc_until = vim.uv.now() - 1
        ui.esc(st)
        eq("x", text())
        ui.ctrl_c(st)
        eq("", text())
      end)

      it("режим input_vim_mode = true оставляет обычный Vim в поле ввода", function()
        config.setup({ input_vim_mode = true })
        local other = real(tmp) .. "/vimproj"
        vim.fn.mkdir(other, "p")
        local st = ui.state(other)
        local esc_map = vim.api.nvim_buf_call(st.input_buf, function() return vim.fn.maparg("<Esc>", "i", false, true) end)
        ok(esc_map.buffer ~= 1, "Esc в поле ввода не перехватывается (остаётся обычный Vim)")
        eq(0, #vim.api.nvim_get_autocmds({ group = "aqua_ai_input_" .. st.input_buf, event = "InsertLeave" }))
        config.setup({ input_vim_mode = false })
        vim.api.nvim_buf_delete(st.chat_buf, { force = true })
        vim.api.nvim_buf_delete(st.input_buf, { force = true })
        ui.states[other] = nil
      end)

      it("скрыть и показать: переписка сохраняется", function()
        local st = ui.visible_state()
        local before = chat_text(st)
        ai.toggle()
        eq(nil, ui.visible_state())
        eq(1, #wins(), "осталось только окно редактора")
        ok(vim.api.nvim_buf_is_valid(st.chat_buf))
        ai.toggle()
        local st2 = ui.visible_state()
        eq(st.chat_buf, st2.chat_buf)
        eq(before, chat_text(st2))
      end)

      it("слэш-команды: /yolo и /new", function()
        local st = ui.visible_state()
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "/yolo" })
        ui.submit(st)
        wait(2000, function() return st.session.yolo end, "yolo включён")
        ui.submit(st) -- поле ввода уже пустое — ничего не делает
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "/yolo" })
        ui.submit(st)
        wait(2000, function() return not st.session.yolo end, "yolo выключен")
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "/new" })
        ui.submit(st)
        wait(2000, function() return #st.session.messages == 0 end, "чат очищен")
        wait(2000, function() return not chat_text(st):find("Готово", 1, true) end)
        ok(chat_text(st):find("Aqua AI", 1, true), "приветствие после очистки")
      end)

      it("добавление файла и выделения в поле ввода", function()
        vim.cmd.edit(proj .. "/main.md")
        ai.send_file()
        local st = ui.visible_state()
        local input = table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\n")
        ok(input:find("@main.md", 1, true), input)
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "" })
        local sel = require("aqua.claude").format_selection(vim.fn.bufnr(proj .. "/main.md"), 1, 3, proj)
        ui.add_to_input(st, sel)
        input = table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\n")
        ok(input:find("@main.md#L1-3", 1, true) and input:find("# Doc", 1, true), input)
        vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "" })
      end)

      it("Claude и Aqua AI не показываются одновременно", function()
        local claude = require("aqua.claude")
        vim.g.aqua_claude_cmd = { "sh", "-c", "exec cat" }
        vim.cmd.edit(proj .. "/main.md")
        local c = claude.open()
        ok(c:valid(), "Claude виден")
        eq(nil, ui.visible_state(), "чат спрятан")
        ai.open()
        ok(ui.visible_state(), "чат открыт")
        ok(not claude.get(proj):valid(), "Claude спрятан")
        claude.kill()
      end)

      it("история переписки восстанавливается при новом запуске интерфейса", function()
        local st = ui.visible_state()
        local s = st.session
        s:reset()
        s.cb = function(ev, ...) ui.on_event(st, ev, ...) end
        s:send("make-file")
        wait(10000, function() return not s.running and chat_text(st):find("Готово", 1, true) end, "ответ")
        ui.hide(st)
        vim.api.nvim_buf_delete(st.chat_buf, { force = true })
        vim.api.nvim_buf_delete(st.input_buf, { force = true })
        ui.states[proj] = nil
        session_mod.sessions[proj] = nil
        local st2 = ui.state(proj)
        local t = chat_text(st2)
        ok(t:find("make-file", 1, true) and t:find("`write_file`", 1, true) and t:find("Готово", 1, true), t)
        os.remove(proj .. "/notes/hello.md")
        st2.session:reset()
      end)

      it("бинды, команда :AquaAI и статус для lualine", function()
        for _, lhs in ipairs({ " o", " aon", " aom", " aop", " aof", " aod", " aoc", " aoy", " aot" }) do
          ok(vim.fn.maparg(lhs, "n") ~= "", "нет бинда " .. lhs)
        end
        ok(vim.fn.maparg(" aos", "x") ~= "", "визуальный бинд")
        eq(2, vim.fn.exists(":AquaAI"))
        local msg
        local orig = vim.notify
        vim.notify = function(m) msg = m end
        vim.cmd("AquaAI tools")
        vim.notify = orig
        ok(msg and msg:find("write_file", 1, true) and msg:find("md_write_section", 1, true) and msg:find("web_search", 1, true), tostring(msg))
        ok(type(ai.status()) == "string")
      end)

      it("тема: подсветка Aqua AI задана", function()
        for _, g in ipairs({ "AquaAINormal", "AquaAIBar", "AquaAIUser", "AquaAIBot", "AquaAITool", "AquaAIErr", "AquaAIPromptTitle" }) do
          ok(next(vim.api.nvim_get_hl(0, { name = g })), g)
        end
      end)
    end)
  end

  -- ── Уборка ────────────────────────────────────────────────────────────────
  if server then pcall(function() server:kill(15) end) end
  config.user = {}
  -- состояние тестов (модели, сессии) не должно «просачиваться» в ручные запуски
  local state_dir = vim.fn.stdpath("state") .. "/aqua_ai"
  if state_dir:find("/.tests/", 1, true) then
    vim.fn.delete(state_dir, "rf")
  end
  pcall(function() require("aqua.ai.ui").hide_all() end)
end
