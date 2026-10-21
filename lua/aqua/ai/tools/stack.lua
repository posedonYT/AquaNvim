-- Инструменты «стек и документация»: модель узнаёт точные версии стека, читает официальные
-- заметки о выпусках и документацию пакетов, смотрит локальный API (go doc, .d.ts) и проверяет
-- свои правки компилятором.
local stack = require("aqua.ai.stack")
local sandbox = require("aqua.ai.tools.sandbox")
local probe = require("aqua.ai.stack.probe")
local version = require("aqua.ai.stack.version")

local M = {}

local function knowledge() return require("aqua.ai.knowledge") end
local function digest() return require("aqua.ai.knowledge.digest") end

--- Разделы сохранённых заметок о выпуске версий проекта, где упоминается имя
--- (например, «uuid» → «New uuid package» в заметках Go 1.27).
local function notes_mentioning(st, name, cfg, max)
  local kn = knowledge()
  local out = {}
  local q = name:lower():gsub("^.*/", "")
  for _, t in ipairs(stack.targets(st)) do
    local info = kn.language_info(t.lang, t.version, cfg)
    local body, meta
    if info then body, meta = kn.read_note(info.path) end -- (`a and f()` теряет второе значение)
    if body then
      for _, h in ipairs(digest().headings(vim.split(body, "\n", { plain = true }), kn.opts(meta))) do
        local title = h.title:lower()
        if title:find(q, 1, true) and (title:find("%f[%w]" .. vim.pesc(q) .. "%f[%W]") or title == q) then
          local text = digest().section(body, h.title, max, kn.opts(meta))
          if text then
            out[#out + 1] = ("From %s release notes (%s):\n%s"):format(info.label, meta and meta.source or info.url, text)
            break
          end
        end
      end
    end
  end
  return #out > 0 and table.concat(out, "\n\n") or nil
end

local function eco_by_id(st, id)
  for _, eco in ipairs(st.ecosystems) do
    if eco.id == id then return eco end
  end
end

--- Версия языка из стека проекта (для lookup_docs без version).
local function stack_version(st, lang)
  for _, t in ipairs(stack.targets(st)) do
    if t.lang == lang then return t.version end
  end
end

-- ── check_project: выбор команды ────────────────────────────────────────────

local EXT_ECO = { go = "go", rs = "rust", ts = "js", tsx = "js", mts = "js", cts = "js", js = "js", py = "python",
  c = "cpp", cc = "cpp", cpp = "cpp", cxx = "cpp", h = "cpp", hpp = "cpp", hh = "cpp" }

local function find_cmake_build(root)
  for _, d in ipairs({ "build", "cmake-build-debug", "cmake-build-release", "out/build", "_build" }) do
    if vim.fn.filereadable(root .. "/" .. d .. "/CMakeCache.txt") == 1 then
      return root .. "/" .. d
    end
  end
end

--- Команда проверки, выбранная харнесом (модель не может передать произвольную команду).
---@return table? plan, string? err
function M.check_command(st, args, ctx)
  local mode = args.mode or "build"
  local files = {}
  for _, f in ipairs(type(args.files) == "table" and args.files or {}) do
    local abs, rel = sandbox.resolve(ctx, f)
    if not abs then return nil, rel end
    if vim.fn.filereadable(abs) ~= 1 then return nil, "Файл не найден: " .. rel end
    files[#files + 1] = { abs = abs, rel = rel }
  end
  local eco_id = args.ecosystem
  if eco_id == "ts" or eco_id == "typescript" or eco_id == "javascript" then eco_id = "js" end
  if eco_id == "c" or eco_id == "c++" then eco_id = "cpp" end
  if not eco_id and #files > 0 then eco_id = EXT_ECO[files[1].abs:match("%.(%w+)$") or ""] end
  if not eco_id then
    if #st.ecosystems == 1 then
      eco_id = st.ecosystems[1].id
    elseif #st.ecosystems == 0 then
      return nil, "В проекте не найдено манифестов (go.mod, Cargo.toml, package.json, pyproject.toml, CMakeLists.txt)"
    else
      return nil, "Укажите ecosystem: " .. table.concat(vim.tbl_map(function(e) return e.id end, st.ecosystems), ", ")
    end
  end
  local eco = eco_by_id(st, eco_id)
  if not eco then
    return nil, ("Экосистема «%s» не найдена в проекте"):format(eco_id)
  end
  local dir = eco.dir or ctx.root
  local env = {}
  local cmd

  if eco_id == "go" then
    if vim.fn.executable("go") ~= 1 then return nil, "Go не установлен" end
    cmd = ({ build = { "go", "build", "./..." }, vet = { "go", "vet", "./..." }, test = { "go", "test", "./..." } })[mode]
    env = { GOTOOLCHAIN = "local" }
  elseif eco_id == "rust" then
    if vim.fn.executable("cargo") ~= 1 then return nil, "cargo не установлен" end
    if mode == "vet" and vim.fn.executable("cargo-clippy") == 1 then
      cmd = { "cargo", "clippy", "--message-format", "short" }
    elseif mode == "test" then
      cmd = { "cargo", "test", "--no-run", "--message-format", "short" }
    else
      cmd = { "cargo", "check", "--message-format", "short" }
    end
  elseif eco_id == "js" then
    local tsc = dir .. "/node_modules/.bin/tsc"
    if mode == "test" then
      return nil, "Запуск тестов JS/TS не поддерживается (это выполнило бы произвольные npm-скрипты). Доступно: build (tsc --noEmit)."
    end
    if vim.fn.executable(tsc) ~= 1 then
      return nil, "TypeScript не установлен в проекте (node_modules/.bin/tsc). Для JS-проектов проверка недоступна."
    end
    cmd = { tsc, "--noEmit", "--pretty", "false" }
  elseif eco_id == "python" then
    local py = vim.fn.executable("python3") == 1 and "python3" or "python"
    if mode == "test" then
      cmd = { py, "-m", "pytest", "-q", "-x" }
    else
      if #files == 0 then
        return nil, "Для Python укажите files (список .py) — будет проверен синтаксис"
      end
      cmd = { py, "-c", "import ast,sys\nfor f in sys.argv[1:]:\n    ast.parse(open(f, encoding='utf-8').read(), f)\nprint('syntax ok:', len(sys.argv)-1, 'file(s)')" }
      for _, f in ipairs(files) do cmd[#cmd + 1] = f.abs end
    end
  elseif eco_id == "cpp" then
    local build = find_cmake_build(ctx.root)
    if build and mode == "test" then
      cmd = { "ctest", "--test-dir", build, "--output-on-failure" }
    elseif build and #files == 0 then
      cmd = { "cmake", "--build", build }
    else
      if #files == 0 then
        return nil, "Нет настроенной сборки CMake (build/CMakeCache.txt) — укажите files для проверки синтаксиса"
      end
      local f = files[1]
      local entry = eco.compile_commands and eco.compile_commands[f.abs]
      if entry then
        cmd = {}
        local skip = false
        for _, a in ipairs(entry.arguments) do
          if skip then skip = false
          elseif a == "-o" then skip = true
          elseif a ~= "-c" and not a:match("^%-o.+") and a ~= f.abs and a ~= vim.fs.basename(f.abs) and not a:match("%.c[cp]?p?$") then
            cmd[#cmd + 1] = a
          end
        end
        dir = entry.directory or dir
        vim.list_extend(cmd, { "-fsyntax-only", f.abs })
      else
        local is_c = f.abs:match("%.c$") ~= nil
        local compiler = is_c and (vim.fn.executable("cc") == 1 and "cc" or "clang") or (vim.fn.executable("c++") == 1 and "c++" or "clang++")
        cmd = { compiler, "-fsyntax-only" }
        local std = is_c and eco.c_std or eco.cxx_std
        if std then cmd[#cmd + 1] = (is_c and "-std=c" or "-std=c++") .. std end
        for _, extra in ipairs(files) do cmd[#cmd + 1] = extra.abs end
      end
    end
  end
  if not cmd then
    return nil, "Режим не поддерживается: " .. tostring(mode)
  end
  return { cmd = cmd, cwd = dir, env = env, eco = eco_id }
end

local function shorten_cmd(plan, root)
  return table.concat(vim.tbl_map(function(a)
    a = a:gsub("^" .. vim.pesc(root) .. "/", "")
    return a:find("[%s\n]") and ("'" .. (a:find("\n") and (a:match("^[^\n]*") .. " …") or a) .. "'") or a
  end, plan.cmd), " ")
end

M.tools = {
  {
    name = "project_stack",
    category = "read",
    description = "Detailed project stack: languages with required and installed versions (go.mod/toolchain, node, python, rustc, C/C++ standard and compiler), all direct dependencies with exact versions from lock files (go.sum, package-lock, uv.lock, Cargo.lock...) and warnings. Use it to know which versions your code must target.",
    parameters = { type = "object", properties = {} },
    summarize = function() return "" end,
    run = function(_, ctx, done)
      done(stack.report(stack.detect(ctx.root)))
    end,
  },

  {
    name = "lookup_docs",
    category = "docs",
    description = "Read OFFICIAL documentation for the exact versions used in this project. name = language (go, python, node, typescript, rust, c++, c, gcc, clang) → release notes of that version (what is new/changed), or a package/module name from the project dependencies (e.g. github.com/redis/go-redis/v9, express, fastapi, tokio) → its docs/README for the locked version. Without section returns a digest with all section titles; pass section to read one section in full. Results are cached.",
    parameters = {
      type = "object",
      properties = {
        name = { type = "string", description = "Language or package name" },
        version = { type = "string", description = "Version (default: the version used by the project)" },
        section = { type = "string", description = "Section title (or part of it) to read in full, e.g. 'Standard library' or 'slices'" },
        ecosystem = { type = "string", enum = { "go", "npm", "pypi", "crates" }, description = "Package registry, if the package is not in the project dependencies" },
      },
      required = { "name" },
    },
    summarize = function(a)
      return a.name .. (a.version and ("@" .. a.version) or "") .. (a.section and (" › " .. a.section) or "")
    end,
    prepare = function(a, ctx)
      return { name = a.name }, { title = "Официальная документация: " .. a.name .. (a.version and (" " .. a.version) or "") }
    end,
    run = function(a, ctx, done)
      local st = stack.detect(ctx.root)
      local kn = knowledge()
      local max = (ctx.cfg.knowledge and ctx.cfg.knowledge.max_chars) or 16000
      local function render(body, meta, label)
        local opts = kn.opts(meta)
        if a.section and a.section ~= "" then
          local text = digest().section(body, a.section, max, opts)
          if not text then
            return done(nil, ("Раздел «%s» не найден в %s. Разделы:\n%s"):format(a.section, label, digest().index(body, 3000, opts)))
          end
          return done(("%s (%s)\n\n%s"):format(label, meta and meta.source or "", text))
        end
        done(("%s (%s)\n\n%s"):format(label, meta and meta.source or "", digest().digest(body, max, opts)))
      end

      local lang = require("aqua.ai.knowledge.sources").language(a.name)
      if lang then
        local v = a.version or stack_version(st, lang)
        if not v then
          return done(nil, ("Версия %s не найдена в стеке проекта — укажите version"):format(lang))
        end
        return kn.ensure_language(lang, v, ctx.cfg, function(body, err, info)
          if not body then return done(nil, err) end
          local _, meta = kn.read_note(info.path)
          render(body, meta, info.label)
        end)
      end

      -- пакет: реестр и версия из стека
      local dep, eco = stack.find_dep(st, a.name)
      local goeco = eco_by_id(st, "go")
      -- Go: имя, которого нет в зависимостях, — вероятно, пакет стандартной библиотеки этой версии
      if not dep and goeco and not a.ecosystem and require("aqua.ai.knowledge.localdocs").valid_go_symbol(a.name) then
        local mention = notes_mentioning(st, a.name, ctx.cfg, 6000)
        return require("aqua.ai.knowledge.localdocs").go_doc(goeco.dir or ctx.root, a.name, false, function(text, gerr)
          if not text and not mention then
            return done(nil, ("«%s» нет ни в зависимостях проекта, ни в стандартной библиотеке Go %s (%s). Укажите ecosystem или используйте web_search."):format(
              a.name, goeco.language_version or "", gerr or ""))
          end
          local parts = {}
          if text then
            parts[#parts + 1] = ("go doc %s — standard library of the INSTALLED Go %s (use it, no third-party dependency needed):\n%s"):format(
              a.name, goeco.installed or goeco.language_version or "", text)
          end
          if mention then parts[#parts + 1] = mention end
          done(table.concat(parts, "\n\n"))
        end)
      end
      if not dep and not a.ecosystem then
        local mention = notes_mentioning(st, a.name, ctx.cfg, 6000)
        if mention then
          return done(mention .. "\n\n(«" .. a.name .. "» — не зависимость проекта; найдено в заметках о выпуске версии языка.)")
        end
      end
      local registry = a.ecosystem or (eco and require("aqua.ai.knowledge.sources").registry_of[eco.id])
      if not registry then
        return done(nil, ("«%s» не найден среди зависимостей проекта. Укажите ecosystem (go/npm/pypi/crates) или используйте web_search."):format(a.name))
      end
      local v = a.version or (dep and dep.version)
      if v and not version.parse(v) then v = nil end
      if registry == "go" then
        -- для Go-модулей главный источник — go doc (точный API версии из go.sum)
        local dir = (eco and eco.dir) or ctx.root
        return require("aqua.ai.knowledge.localdocs").go_doc(dir, a.section and a.section ~= "" and (a.name .. "." .. a.section) or a.name, false, function(text, gerr)
          if text then
            return done(("go doc %s (версия из go.mod: %s)\n\n%s"):format(a.name, dep and dep.version or "?", text))
          end
          kn.ensure_package("go", a.name, v, ctx.cfg, function(body, err, meta)
            if not body then return done(nil, (gerr or "") .. "\n" .. tostring(err)) end
            done(("%s\n%s\n(go doc недоступен: %s. Если модуль не скачан — пользователю: go mod download)"):format(meta and meta.title or a.name, body, gerr or ""))
          end)
        end)
      end
      kn.ensure_package(registry, a.name, v, ctx.cfg, function(body, err, meta)
        if not body then return done(nil, err) end
        render(body, meta, meta and meta.title or a.name)
      end)
    end,
  },

  {
    name = "api_docs",
    category = "read",
    description = "Exact API of the INSTALLED versions, read locally (no network): Go — `go doc` for standard library and module packages (e.g. 'slices', 'slices.Collect', 'net/http.Client', 'github.com/redis/go-redis/v9.Client'); TypeScript/JavaScript — type declarations (.d.ts) of a package in node_modules (symbol optional). Use before calling functions you are not sure exist in this version.",
    parameters = {
      type = "object",
      properties = {
        symbol = { type = "string", description = "Go: package[.Symbol[.Method]]; TS/JS: package name" },
        member = { type = "string", description = "TS/JS: exported name to look for inside the package types" },
        language = { type = "string", enum = { "go", "ts" }, description = "Default: detected from the project" },
        all = { type = "boolean", description = "Go: full package documentation (go doc -all)" },
      },
      required = { "symbol" },
    },
    summarize = function(a) return a.symbol .. (a.member and ("#" .. a.member) or "") end,
    run = function(a, ctx, done)
      local st = stack.detect(ctx.root)
      local lang = a.language
      if not lang then
        lang = eco_by_id(st, "go") and "go" or (eco_by_id(st, "js") and "ts") or nil
      end
      local ld = require("aqua.ai.knowledge.localdocs")
      if lang == "go" then
        local eco = eco_by_id(st, "go")
        return ld.go_doc((eco and eco.dir) or ctx.root, a.symbol, a.all, function(text, err)
          if not text then return done(nil, err) end
          done(text)
        end)
      elseif lang == "ts" then
        local eco = eco_by_id(st, "js")
        local text, err = ld.ts_types((eco and eco.dir) or ctx.root, a.symbol, a.member)
        if not text then return done(nil, err) end
        return done(text)
      end
      done(nil, "Локальная документация доступна для Go (go doc) и TypeScript (.d.ts). Для Python/Rust/C++ используйте lookup_docs.")
    end,
  },

  {
    name = "check_project",
    category = "exec",
    description = "Verify your changes with the real compiler/toolchain of this project and read the errors. The harness picks the command: Go — go build|vet|test ./...; Rust — cargo check|clippy|test --no-run; TypeScript — tsc --noEmit; Python — syntax check of given files (mode=test runs pytest); C/C++ — cmake --build (or -fsyntax-only for given files). Call it after editing code and fix the reported errors.",
    parameters = {
      type = "object",
      properties = {
        mode = { type = "string", enum = { "build", "vet", "test" }, description = "Default: build" },
        ecosystem = { type = "string", enum = { "go", "rust", "js", "python", "cpp" }, description = "If the project has several" },
        files = { type = "array", items = { type = "string" }, description = "Python / C / C++: files to check" },
      },
    },
    summarize = function(a) return (a.mode or "build") .. (a.ecosystem and (" " .. a.ecosystem) or "") end,
    prepare = function(a, ctx)
      local plan, err = M.check_command(stack.detect(ctx.root), a, ctx)
      if not plan then return nil, err end
      return plan, { title = "Выполнить: " .. shorten_cmd(plan, ctx.root) .. "   (папка: " .. sandbox.rel(ctx, plan.cwd) .. ")" }
    end,
    run = function(_, ctx, done, plan)
      local uv = vim.uv or vim.loop
      local timeout = ((ctx.cfg.check and ctx.cfg.check.timeout) or 120) * 1000
      local head = "$ " .. shorten_cmd(plan, ctx.root)
      local chunks, finished, obj, timer, handle = {}, false, nil, nil, nil
      local function output()
        local out = vim.trim(table.concat(chunks)):gsub(vim.pesc(ctx.root) .. "/", "")
        if #out > 8000 then out = out:sub(1, 4000) .. "\n... [вывод сокращён] ...\n" .. out:sub(-4000) end
        return out
      end
      local function finish(code, why)
        if finished then return end
        finished = true
        if timer then timer:stop() timer:close() timer = nil end
        if ctx.session and ctx.session.child == handle then ctx.session.child = nil end
        local out = output()
        if why == "timeout" then
          return done(nil, ("%s\nexit: превышено время ожидания (%d с), процесс остановлен\n%s"):format(head, timeout / 1000, out))
        elseif why == "cancel" then
          return done(nil, head .. "\nпрервано пользователем")
        elseif code ~= 0 then
          return done(nil, ("%s\nexit code: %d\n%s"):format(head, code, out))
        end
        done(head .. "\nexit code: 0 — без ошибок" .. (out ~= "" and ("\n" .. out) or ""))
      end
      -- Процесс запускается своей группой (detach), чтобы при таймауте/отмене остановить и его
      -- дочерние процессы (go test, cargo, make…), иначе они держат вывод открытым.
      local function kill_tree()
        if obj and obj.pid then
          pcall(uv.kill, -obj.pid, "sigterm")
          pcall(uv.kill, obj.pid, "sigkill")
        end
      end
      local collect = function(_, data) if data then chunks[#chunks + 1] = data end end
      local ok, started = pcall(vim.system, plan.cmd, {
        cwd = plan.cwd, env = plan.env, text = true, detach = true, stdout = collect, stderr = collect,
      }, function(res)
        vim.schedule(function() finish(res.code) end)
      end)
      if not ok then
        return done(nil, "Не удалось запустить: " .. tostring(started))
      end
      obj = started
      timer = assert(uv.new_timer())
      timer:start(timeout, 0, vim.schedule_wrap(function()
        kill_tree()
        finish(124, "timeout")
      end))
      handle = {
        kill = function()
          kill_tree()
          finish(130, "cancel")
        end,
      }
      if ctx.session then ctx.session.child = handle end
    end,
  },
}

M.version_of = stack_version
M.probe = probe
return M
