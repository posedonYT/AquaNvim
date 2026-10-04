-- Headless-тесты AquaNvim. Запуск: `make test`
-- Каждый тест изолирован настолько, насколько позволяет один процесс Neovim;
-- временные проекты создаются во временной директории.
local results = { passed = 0, failed = 0, errors = {} }
local function print(...)
  io.stdout:write(table.concat(vim.tbl_map(tostring, { ... }), " ") .. "\n")
end
local current_group = ""

local function describe(name, fn)
  current_group = name
  print(("\n≋ %s"):format(name))
  fn()
end

local function it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.passed = results.passed + 1
    print(("  ✓ %s"):format(name))
  else
    results.failed = results.failed + 1
    table.insert(results.errors, ("%s › %s\n%s"):format(current_group, name, err))
    print(("  ✗ %s\n      %s"):format(name, tostring(err):gsub("\n", "\n      ")))
  end
end

local function eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function ok(value, msg)
  if not value then
    error(msg or "expected truthy value", 2)
  end
end

local function wait(ms, cond, msg)
  if not vim.wait(ms, cond, 20) then
    error("timeout: " .. (msg or "condition"), 2)
  end
end

local uv = vim.uv or vim.loop
local function real(p) return uv.fs_realpath(p) or p end

-- ── Временные проекты ──────────────────────────────────────────────────────
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = real(tmp)
local proj = tmp .. "/proj" -- git-проект
local proj2 = tmp .. "/web" -- проект с package.json, без git
local loose = tmp .. "/loose" -- просто папка
vim.fn.mkdir(proj .. "/src/deep", "p")
vim.fn.mkdir(proj2 .. "/app", "p")
vim.fn.mkdir(loose, "p")
vim.fn.system({ "git", "init", "-q", proj })
vim.fn.writefile({ "local x = 1", "local y = 2", "return x + y" }, proj .. "/src/deep/a.lua")
vim.fn.writefile({ "print('main')" }, proj .. "/main.lua")
vim.fn.writefile({ "{}" }, proj2 .. "/package.json")
vim.fn.writefile({ "console.log(1)" }, proj2 .. "/app/index.js")
vim.fn.writefile({ "hello" }, loose .. "/note.txt")

local extras_file = tmp .. "/aquanvim.json"
vim.env.AQUA_EXTRAS_FILE = extras_file

-- Фейковый Claude: печатает свою рабочую директорию и эхо ввода
vim.g.aqua_claude_cmd = { "sh", "-c", "echo CWD=$(pwd -P); exec cat" }

local function run()
  -- В headless нет UIEnter → VeryLazy вручную
  vim.cmd("doautocmd User VeryLazy")
  vim.wait(200)

  describe("Старт", function()
    it("тема aqua активна", function()
      eq("aqua", vim.g.colors_name)
      local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
      eq(tonumber(require("aqua.theme.palette").deep:sub(2), 16), normal.bg, "фон Normal")
      ok(next(vim.api.nvim_get_hl(0, { name = "AquaHeader1" })), "градиент заголовка")
    end)

    it("нет ошибок при запуске", function()
      local msgs = vim.fn.execute("messages")
      ok(not msgs:match("E%d+:") and not msgs:match("[Ee]rror"), "сообщения:\n" .. msgs)
    end)

    it("все модули aqua загружаются", function()
      for _, mod in ipairs({
        "aqua", "aqua.util.root", "aqua.claude", "aqua.session", "aqua.extras",
        "aqua.theme", "aqua.theme.palette",
        "aqua.plugins.ui", "aqua.plugins.snacks", "aqua.plugins.editor", "aqua.plugins.lsp",
        "aqua.plugins.formatting", "aqua.plugins.treesitter", "aqua.plugins.completion",
      }) do
        local success, err = pcall(require, mod)
        ok(success, mod .. ": " .. tostring(err))
      end
    end)

    it("ключевые плагины загружены", function()
      for _, name in ipairs({ "snacks.nvim", "which-key.nvim", "lualine.nvim", "tokyonight.nvim" }) do
        ok(require("lazy.core.config").plugins[name]._.loaded, name .. " не загружен")
      end
      ok(Snacks ~= nil, "глобальный Snacks")
    end)
  end)

  describe("Бинды и меню", function()
    local function has(lhs, mode)
      return vim.fn.maparg(vim.keycode(lhs), mode or "n") ~= "" or vim.fn.maparg(lhs, mode or "n") ~= ""
    end
    it("фирменные бинды AquaNvim сохранены", function()
      ok(has("<C-s>"), "<C-s>")
      ok(has("<C-s>", "i"), "<C-s> insert")
      ok(has("<C-a>"), "<C-a>")
      ok(has("/", "x"), "визуальный / комментирует")
      ok(has("<leader>n"), "<leader>n новый файл")
    end)
    it("меню Space как в LazyVim", function()
      for _, lhs in ipairs({
        "<leader>c", "<leader>e", "<leader>E", "<leader><space>", "<leader>/", "<leader>,",
        "<leader>-", "<leader>|", "<leader>.", "<leader>:", "<leader>?", "<leader>`",
        "<leader>ff", "<leader>fr", "<leader>gg", "<leader>qs", "<leader>qS", "<leader>ql",
        "<leader>aC", "<leader>af", "<leader>X", "<leader>L", "<leader>bd", "<leader>us",
      }) do
        ok(has(lhs), lhs .. " не назначен")
      end
      ok(has("<leader>as", "x"), "<leader>as (visual)")
    end)
    it("<leader>c — прямое действие, без подгрупп (нет задержки)", function()
      local leader = vim.g.mapleader
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        local lhs = m.lhs:gsub("^" .. vim.pesc(leader), "<leader>")
        ok(not lhs:match("^<leader>c.+"), "конфликтующий бинд " .. m.lhs)
      end
    end)
    it("which-key: preset helix и группы", function()
      eq("helix", require("which-key.config").options.preset)
      local opts = require("aqua.plugins.editor")[1].opts
      local groups = {}
      for _, spec in ipairs(opts.spec[1]) do
        if type(spec) == "table" and spec.group then
          groups[spec[1]] = spec.group
        end
      end
      for _, g in ipairs({ "<leader>a", "<leader>f", "<leader>g", "<leader>q", "<leader>s", "<leader>u", "<leader>l" }) do
        ok(groups[g], "группа " .. g)
      end
    end)
  end)

  describe("Определение корня проекта", function()
    local root = require("aqua.util.root")
    it(".git → корень репозитория", function()
      vim.cmd.edit(proj .. "/src/deep/a.lua")
      eq(proj, root.get())
      eq(proj .. "/src/deep", root.file_dir())
    end)
    it("маркер package.json без git", function()
      vim.cmd.edit(proj2 .. "/app/index.js")
      eq(proj2, root.get())
    end)
    it("без маркеров → папка файла", function()
      vim.cmd.edit(loose .. "/note.txt")
      eq(loose, root.get())
    end)
    it("из служебного буфера берётся последний файл", function()
      vim.cmd.edit(proj .. "/main.lua")
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      eq(proj, root.get())
      vim.cmd("bwipe!")
    end)
  end)

  describe("Claude CLI", function()
    local claude = require("aqua.claude")
    local function term_text(term)
      -- окно узкое: длинные строки переносятся, поэтому склеиваем без разделителя
      return table.concat(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false), "")
    end
    local function wait_cwd(term, cwd)
      wait(3000, function() return term_text(term):find("CWD=" .. cwd, 1, true) ~= nil end, "CWD=" .. cwd .. "\n" .. term_text(term))
    end

    it("Space+c открывает Claude справа в корне проекта", function()
      vim.cmd("only")
      vim.cmd.edit(proj .. "/src/deep/a.lua")
      local editor_win = vim.api.nvim_get_current_win()
      local term = claude.toggle()
      ok(term and term:valid(), "окно Claude открыто")
      local pos = vim.api.nvim_win_get_position(term.win)
      local editor_pos = vim.api.nvim_win_get_position(editor_win)
      ok(pos[2] > editor_pos[2], "Claude справа от редактора")
      local width = vim.api.nvim_win_get_width(term.win)
      ok(math.abs(width - math.floor(vim.o.columns * 0.4)) <= 2, "ширина ~40%: " .. width)
      eq(proj, vim.b[term.buf].aqua_claude_cwd)
      wait_cwd(term, proj)
    end)

    it("повторное нажатие прячет, процесс остаётся жив", function()
      local term = claude.get(proj)
      local buf = term.buf
      vim.cmd("wincmd p") -- вернулись в редактор
      claude.toggle()
      ok(not term:valid(), "окно скрыто")
      ok(vim.api.nvim_buf_is_valid(buf), "буфер жив")
      local again = claude.toggle()
      eq(buf, again.buf, "тот же экземпляр")
      ok(again:valid(), "снова показан")
    end)

    it("из окна Claude toggle прячет именно его", function()
      local term = claude.get(proj)
      term:focus()
      claude.toggle()
      ok(not term:valid())
    end)

    it("<leader>aC — папка текущего файла (отдельный экземпляр)", function()
      vim.cmd.edit(proj .. "/src/deep/a.lua")
      local term = claude.toggle({ scope = "file" })
      eq(proj .. "/src/deep", vim.b[term.buf].aqua_claude_cwd)
      wait_cwd(term, proj .. "/src/deep")
      ok(term.buf ~= claude.get(proj).buf, "разные экземпляры")
      term:hide()
    end)

    it("другой проект → свой Claude", function()
      vim.cmd("wincmd p")
      vim.cmd.edit(proj2 .. "/app/index.js")
      local term = claude.toggle()
      wait_cwd(term, proj2)
      eq(3, vim.tbl_count(claude.list()))
      term:hide()
    end)

    it("отправка файла и выделения", function()
      vim.cmd.edit(proj .. "/src/deep/a.lua")
      claude.send_file()
      local term = claude.get(proj)
      wait(3000, function() return term_text(term):find("@src/deep/a.lua", 1, true) ~= nil end, "ссылка на файл\n" .. term_text(term))
      local msg = claude.format_selection(vim.fn.bufnr(proj .. "/src/deep/a.lua"), 1, 2, proj)
      eq("@src/deep/a.lua#L1-2\n```lua\nlocal x = 1\nlocal y = 2\n```\n", msg)
      term:hide()
    end)

    it("статус для lualine", function()
      vim.cmd.edit(proj .. "/main.lua")
      ok(claude.status():find("󰚩"), claude.status())
    end)

    it("kill завершает экземпляр", function()
      vim.cmd.edit(proj2 .. "/app/index.js")
      claude.kill()
      eq(nil, claude.get(proj2))
      eq(2, vim.tbl_count(claude.list()))
    end)

    it("понятная ошибка, если CLI не установлен", function()
      local saved = vim.g.aqua_claude_cmd
      vim.g.aqua_claude_cmd = "definitely-not-claude-cli"
      local notified
      local orig = vim.notify
      vim.notify = function(msg) notified = msg end
      local term = claude.open()
      vim.notify = orig
      vim.g.aqua_claude_cmd = saved
      eq(nil, term)
      ok(notified and notified:find("не найден"), "уведомление")
    end)
  end)

  describe("Explorer", function()
    it("Snacks Explorer открывается слева в корне проекта", function()
      vim.cmd("only")
      vim.cmd.edit(proj .. "/main.lua")
      Snacks.explorer({ cwd = require("aqua.util.root").get() })
      wait(3000, function() return #Snacks.picker.get({ source = "explorer" }) > 0 end, "explorer")
      local picker = Snacks.picker.get({ source = "explorer" })[1]
      eq(proj, real(picker:cwd()))
      wait(3000, function() return picker:count() > 0 end, "элементы")
      picker:close()
    end)
  end)

  describe("Сессии", function()
    local persistence = require("persistence")
    it("служебные окна не попадают в сессию", function()
      vim.cmd("only")
      vim.cmd.cd(proj)
      vim.cmd.edit(proj .. "/main.lua")
      vim.cmd.vsplit(proj .. "/src/deep/a.lua")
      Snacks.explorer()
      wait(3000, function() return #Snacks.picker.get({ source = "explorer" }) > 0 end)
      require("aqua.claude").open()
      persistence.start()
      ok(require("aqua.session").save(), "session.save")
      local file = persistence.current()
      ok(vim.fn.filereadable(file) == 1, "файл сессии " .. file)
      local content = table.concat(vim.fn.readfile(file), "\n")
      ok(not content:find("term://", 1, true), "терминал в сессии")
      ok(not content:find("snacks_", 1, true), "snacks-окна в сессии")
      ok(content:find("main.lua", 1, true) and content:find("a.lua", 1, true), "файлы в сессии")
      eq(0, #Snacks.picker.get({ source = "explorer" }), "explorer закрыт перед сохранением")
    end)

    it("восстановление сессии", function()
      for cwd in pairs(require("aqua.claude").list()) do
        require("aqua.claude").kill({ cwd = cwd })
      end
      vim.cmd("silent! %bwipe!")
      persistence.load()
      vim.wait(100)
      local names = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].buflisted then
          names[#names + 1] = vim.fs.basename(vim.api.nvim_buf_get_name(b))
        end
      end
      ok(vim.tbl_contains(names, "main.lua") and vim.tbl_contains(names, "a.lua"), vim.inspect(names))
      local normal = vim.tbl_filter(function(w)
        return vim.api.nvim_win_get_config(w).relative == ""
      end, vim.api.nvim_tabpage_list_wins(0))
      eq(2, #normal, "раскладка восстановлена")
    end)

    it("при смене проекта сессия старого сохраняется", function()
      local file = persistence.current()
      os.remove(file)
      vim.cmd.cd(proj2)
      ok(vim.fn.filereadable(file) == 1, "сессия proj сохранена при :cd")
      vim.cmd.cd(proj)
    end)
  end)

  describe("Extras", function()
    local extras = require("aqua.extras")
    it("по умолчанию — набор прежнего AquaNvim", function()
      os.remove(extras_file)
      eq(extras.defaults, extras.enabled())
    end)
    it("каждый extra имеет описание и корректную спеку", function()
      local all = extras.all()
      ok(#all >= 20, "extras: " .. #all)
      for _, e in ipairs(all) do
        ok(e.desc ~= "", e.name .. ": нет `-- desc:`")
        local success, spec = pcall(dofile, e.file)
        ok(success and type(spec) == "table", e.name .. ": " .. tostring(spec))
      end
    end)
    it("enable / disable пишут aquanvim.json", function()
      eq(true, extras.set("lang.go", true))
      ok(vim.tbl_contains(extras.enabled(), "lang.go"))
      local data = vim.json.decode(table.concat(vim.fn.readfile(extras_file), "\n"))
      ok(vim.tbl_contains(data.extras, "lang.go"), "json")
      eq(false, extras.set("lang.go"))
      ok(not vim.tbl_contains(extras.enabled(), "lang.go"))
      ok(not pcall(extras.set, "lang.nope", true), "несуществующий extra")
    end)
    it("все extras вместе собираются lazy без конфликтов", function()
      local Spec = require("lazy.core.plugin").Spec
      local spec = { { import = "aqua.plugins" } }
      for _, e in ipairs(extras.all()) do
        spec[#spec + 1] = { import = e.module }
      end
      local s = Spec.new(spec)
      local errors = {}
      for _, n in ipairs(s.notifs) do
        if n.level >= vim.log.levels.WARN then
          errors[#errors + 1] = n.msg
        end
      end
      eq({}, errors)
      ok(s.plugins["rustaceanvim"] and s.plugins["vim-dadbod-ui"] and s.plugins["nvim-dap"], "плагины extras в спеке")
    end)
    it(":AquaExtras открывает меню и переключает", function()
      extras.picker()
      wait(2000, function() return #Snacks.picker.get() > 0 end, "picker")
      local picker = Snacks.picker.get()[1]
      wait(2000, function() return picker:count() == #extras.all() end, "все extras в списке")
      picker:close()
      vim.cmd("AquaExtras enable ui.colorizer")
      ok(vim.tbl_contains(extras.enabled(), "ui.colorizer"))
      vim.cmd("AquaExtras disable ui.colorizer")
      ok(not vim.tbl_contains(extras.enabled(), "ui.colorizer"))
    end)
  end)

  describe("LSP", function()
    it("серверы из extras включены через vim.lsp.enable", function()
      require("lazy").load({ plugins = { "nvim-lspconfig" } })
      for _, s in ipairs({ "lua_ls", "vtsls", "pyright", "prismals", "jsonls" }) do
        ok(vim.lsp.is_enabled(s), s)
      end
      ok(not vim.lsp.is_enabled("rust_analyzer"), "rust_analyzer запускает rustaceanvim")
    end)
    it("blink.cmp подключён", function()
      require("lazy").load({ plugins = { "blink.cmp" } })
      ok(pcall(require, "blink.cmp"))
    end)
  end)

  describe("Дашборд", function()
    it("отрисовывается с логотипом и кнопками", function()
      vim.cmd("only")
      vim.cmd("enew")
      Snacks.dashboard.open({ buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win() })
      wait(2000, function() return vim.bo.filetype == "snacks_dashboard" end, "filetype")
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      ok(text:find("dive deep", 1, true), "слоган")
      ok(text:find("██", 1, true), "логотип")
      for _, s in ipairs({ "Restore Session", "Claude", "Aqua Extras", "Projects" }) do
        ok(text:find(s, 1, true), s)
      end
    end)
  end)

  -- ── Итог ────────────────────────────────────────────────────────────────
  print(("\n≋≋≋ %d passed, %d failed ≋≋≋"):format(results.passed, results.failed))
  vim.fn.delete(tmp, "rf")
  vim.cmd(results.failed > 0 and "cquit 1" or "qall!")
end

vim.schedule(function()
  local success, err = xpcall(run, debug.traceback)
  if not success then
    print("FATAL: " .. tostring(err))
    vim.cmd("cquit 2")
  end
end)
