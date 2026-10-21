-- Aqua AI — собственный агентский «харнес» внутри Neovim.
-- Подключает локальную (или любую OpenAI-совместимую) модель и даёт ей инструменты:
-- чтение / создание / изменение / перемещение / удаление файлов и папок в проекте,
-- поиск по проекту, поиск в интернете, работа с Markdown по разделам.
--
--   Space o   — открыть/скрыть чат-терминал справа (в корне проекта текущего файла)
--   :AquaAI   — команды (model, profile, new, yolo, tools, ...)
local config = require("aqua.ai.config")
local root_util = require("aqua.util.root")

local M = {}

M.setup = config.setup
M.config = config
M.register_tool = function(tool) require("aqua.ai.tools").register(tool) end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Aqua AI" })
end

--- Корень проекта для чата (контекст — последний файловый буфер).
function M.root()
  return root_util.get()
end

local function ui() return require("aqua.ai.ui") end

function M.toggle()
  return ui().toggle(M.root())
end

function M.open()
  return ui().open(M.root())
end

function M.hide()
  local st = ui().visible_state()
  if st then ui().hide(st) end
end

function M.hide_all()
  if package.loaded["aqua.ai.ui"] then
    ui().hide_all()
  end
end

--- Состояние интерфейса для текущего проекта (создаёт при необходимости).
local function current_state()
  return ui().state(M.root())
end

--- Отправить сообщение модели (открывает чат).
---@param text string
function M.send(text)
  local st = M.open()
  local ok, err = st.session:send(text)
  if not ok then notify(err, vim.log.levels.WARN) end
end

--- Добавить в поле ввода ссылку на текущий файл.
function M.send_file()
  local buf = root_util.context_buf()
  if not root_util.is_file_buf(buf) then
    return notify("Нет файла для добавления", vim.log.levels.WARN)
  end
  local st = ui().open(M.root())
  ui().add_to_input(st, "@" .. require("aqua.claude").relpath(buf, st.root) .. " ")
end

--- Добавить в поле ввода выделение (с путём и номерами строк).
function M.send_selection()
  local buf = vim.api.nvim_get_current_buf()
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  if l1 > l2 then l1, l2 = l2, l1 end
  vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
  local st = ui().open(M.root())
  ui().add_to_input(st, require("aqua.claude").format_selection(buf, l1, l2, st.root))
end

--- Добавить в поле ввода диагностику текущей строки.
function M.send_diagnostics()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local diags = vim.diagnostic.get(buf, { lnum = lnum - 1 })
  if #diags == 0 then
    return notify("На строке нет диагностик")
  end
  local msgs = {}
  for _, d in ipairs(diags) do
    msgs[#msgs + 1] = ("- [%s] %s"):format(vim.diagnostic.severity[d.severity], d.message)
  end
  local st = ui().open(M.root())
  ui().add_to_input(st, require("aqua.claude").format_selection(buf, lnum, lnum, st.root) .. "Диагностика:\n" .. table.concat(msgs, "\n") .. "\n\nИсправь это.")
end

function M.new_chat()
  local st = current_state()
  st.session:reset()
  notify("Новый чат")
end

function M.cancel()
  local st = current_state()
  if st.session.running then
    local queued = #st.session.queue
    st.session:cancel()
    if queued > 0 then
      notify(("Прервано. Очередь очищена (сообщений: %d)"):format(queued), vim.log.levels.WARN)
    end
  end
end

function M.toggle_yolo()
  local st = current_state()
  st.session.yolo = not st.session.yolo
  vim.cmd("redrawstatus!")
  if st.session.yolo then
    notify("⚡ YOLO: все действия выполняются БЕЗ подтверждения до конца сессии (удалённое попадает в корзину)", vim.log.levels.WARN)
  else
    notify("Подтверждения включены")
  end
end

---@param name string
function M.set_model(name)
  local profile = config.profile()
  config.set_model(profile.name, name)
  notify(("Модель: %s (%s)"):format(name, profile.name))
  vim.cmd("redrawstatus!")
end

---@param cb? fun(ok: boolean)
function M.select_model(cb)
  local profile = config.profile()
  require("aqua.ai.provider").list_models(profile, function(models, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return cb and cb(false)
    end
    if #models == 0 then
      notify("На сервере нет моделей", vim.log.levels.WARN)
      return cb and cb(false)
    end
    vim.ui.select(models, {
      prompt = ("Модель (%s)"):format(profile.name),
      format_item = function(m) return (m == profile.model and "● " or "  ") .. m end,
    }, function(choice)
      if choice then
        M.set_model(choice)
      end
      if cb then cb(choice ~= nil) end
    end)
  end)
end

function M.select_profile()
  local profile, cfg = config.profile()
  local names = vim.tbl_keys(cfg.profiles)
  table.sort(names)
  vim.ui.select(names, {
    prompt = "Профиль модели",
    format_item = function(n)
      local p = cfg.profiles[n]
      return ("%s%s  [%s %s]"):format(n == profile.name and "● " or "  ", n, p.provider, p.host)
    end,
  }, function(choice)
    if choice then
      config.set_profile(choice)
      local p = config.profile()
      notify(("Профиль: %s → %s"):format(choice, p.model or "модель не выбрана (:AquaAI model)"))
      vim.cmd("redrawstatus!")
    end
  end)
end

function M.tools_info()
  local tools = require("aqua.ai.tools")
  local _, cfg = config.profile()
  local lines = { "Инструменты Aqua AI (права: " .. vim.inspect(cfg.permissions):gsub("%s+", " ") .. ")", "" }
  for _, t in ipairs(tools.list) do
    lines[#lines + 1] = ("• %-16s [%s → %s]  %s"):format(t.name, t.category, cfg.permissions[t.category] or "ask", t.description:match("^[^.]*"))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Файловые операции ограничены корнем проекта: " .. M.root()
  notify(table.concat(lines, "\n"))
end

-- ── Стек и знания о версиях ─────────────────────────────────────────────────

--- Отчёт о стеке текущего проекта (текст).
function M.stack_report()
  local stack = require("aqua.ai.stack")
  local st = stack.detect(M.root())
  local kn = require("aqua.ai.knowledge")
  local _, cfg = config.profile()
  local lines = { "# Стек проекта: " .. vim.fn.fnamemodify(st.root, ":~"), "", stack.report(st) }
  local targets = stack.targets(st)
  if #targets > 0 then
    lines[#lines + 1] = "## Заметки о версиях"
    for _, t in ipairs(targets) do
      local info = kn.language_info(t.lang, t.version, cfg)
      local cached = info and vim.fn.filereadable(info.path) == 1
      lines[#lines + 1] = ("- %s: %s"):format(t.label, cached and ("изучено (" .. info.url .. ")") or "ещё не изучено — :AquaAI research")
    end
  end
  return table.concat(lines, "\n")
end

--- Показать стек в окне.
function M.show_stack()
  local text = M.stack_report()
  Snacks.win({
    text = vim.split(text, "\n", { plain = true }),
    ft = "markdown",
    width = 0.7,
    height = 0.7,
    border = "rounded",
    title = " 󰙅 Стек проекта · Aqua AI ",
    title_pos = "center",
    wo = { wrap = true, conceallevel = 2, spell = false },
    keys = { q = "close" },
  })
  return text
end

--- Сохранённые заметки о версиях (открываются как Markdown — работает режим чтения Space m r).
function M.knowledge_picker()
  local kn = require("aqua.ai.knowledge")
  if #kn.list() == 0 then
    return notify("Заметок пока нет. Они появятся после первого запроса в проекте или по :AquaAI research")
  end
  Snacks.picker.files({ cwd = kn.dir(), title = "󰂺 Заметки о версиях стека" })
end

--- Изучить (заново) документацию версий стека текущего проекта.
---@param force? boolean перезагрузить, даже если уже в кэше
---@param cb? fun(results: table[])
function M.research(force, cb)
  local stack = require("aqua.ai.stack")
  local kn = require("aqua.ai.knowledge")
  local _, cfg = config.profile()
  local targets = stack.targets(stack.detect(M.root()))
  if #targets == 0 then
    notify("В проекте не найдено манифестов с версиями (go.mod, package.json, pyproject.toml, Cargo.toml, CMakeLists.txt)")
    return cb and cb({})
  end
  local results, i = {}, 0
  local function nxt()
    i = i + 1
    local t = targets[i]
    if not t then
      local lines = vim.tbl_map(function(r) return (r.ok and "✓ " or "✗ ") .. r.label .. (r.err and (": " .. r.err) or "") end, results)
      notify("Изучение стека:\n" .. table.concat(lines, "\n"))
      return cb and cb(results)
    end
    notify("Изучаю " .. t.label .. "…")
    kn.ensure_language(t.lang, t.version, cfg, function(body, err)
      results[#results + 1] = { label = t.label, ok = body ~= nil, err = err }
      nxt()
    end, force ~= false)
  end
  nxt()
end

--- Подсказка по клавишам и командам (Markdown).
function M.help_text()
  return table.concat({
    "## Клавиши чата",
    "- `Enter` — отправить · `Shift+Enter` / `Alt+Enter` / `Ctrl-J` / `\\` + `Enter` — новая строка",
    "- Пока модель отвечает, можно писать дальше: сообщения встают в очередь (⏳)",
    "- `Esc` / `Ctrl-C` — остановить ответ и очистить очередь · `Ctrl-C` без ответа — очистить ввод",
    "- `Esc Esc` — режим Normal: прокрутка, поиск, копирование, `gf` — открыть файл; `i` — снова ввод",
    "- `Ctrl-H` / `Ctrl-K` / `Ctrl-W …` — перейти в другое окно · `Ctrl-,` или `Space o` — скрыть чат",
    "- `↑` / `↓` — история · `Ctrl-A` / `Ctrl-E` / `Ctrl-K` / `Ctrl-U` / `Alt-B` / `Alt-F` — как в терминале",
    "",
    "## Команды",
    "- `/new` — новый чат · `/model` — модель · `/profile` — профиль · `/yolo` — без подтверждений",
    "- `/stack` — стек проекта · `/research` — заново изучить версии · `/knowledge` — заметки о версиях",
    "- `/tools` — инструменты и права · `/stop` — прервать · `/exit` — закрыть окно чата · `Tab` — дополнить команду",
    "- `@путь` — ссылка на файл проекта (`Space a o f` добавляет текущий)",
  }, "\n")
end

function M.help()
  notify(M.help_text())
end

--- Для lualine.
function M.status()
  return package.loaded["aqua.ai.ui"] and ui().statusline() or ""
end

function M.create_command()
  local subs = { "toggle", "open", "hide", "new", "model", "profile", "stop", "yolo", "tools", "help", "stack", "knowledge", "research" }
  vim.api.nvim_create_user_command("AquaAI", function(c)
    local sub, rest = c.fargs[1] or "toggle", table.concat(vim.list_slice(c.fargs, 2), " ")
    if sub == "toggle" then M.toggle()
    elseif sub == "open" then M.open()
    elseif sub == "hide" then M.hide()
    elseif sub == "new" then M.new_chat()
    elseif sub == "model" then
      if rest ~= "" then M.set_model(rest) else M.select_model() end
    elseif sub == "profile" then M.select_profile()
    elseif sub == "stop" then M.cancel()
    elseif sub == "yolo" then M.toggle_yolo()
    elseif sub == "tools" then M.tools_info()
    elseif sub == "help" then M.help()
    elseif sub == "stack" then M.show_stack()
    elseif sub == "knowledge" then M.knowledge_picker()
    elseif sub == "research" then M.research(true)
    else notify("Неизвестная подкоманда. Доступно: " .. table.concat(subs, ", "), vim.log.levels.WARN) end
  end, {
    nargs = "*",
    desc = "Aqua AI",
    complete = function(_, line)
      if #vim.split(line, "%s+") <= 2 then return subs end
    end,
  })
end

return M
