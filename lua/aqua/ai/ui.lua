-- Интерфейс чата Aqua AI: окно переписки (markdown) + поле ввода справа от редактора.
local config = require("aqua.ai.config")
local session_mod = require("aqua.ai.session")

local M = {}

---@class aqua.ai.UI
---@field root string
---@field session aqua.ai.Session
---@field chat_buf integer
---@field input_buf integer
---@field chat_win? integer
---@field input_win? integer
---@field status string
---@field tool_lines table<string, integer>
---@field history string[]
---@field spinner integer

---@type table<string, aqua.ai.UI>
M.states = {}

local ns = vim.api.nvim_create_namespace("aqua_ai_chat")
local ns_queue = vim.api.nvim_create_namespace("aqua_ai_queue")
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ICON = "\u{f06a9}"

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- ── Запись в буфер чата ─────────────────────────────────────────────────────

local function mod(buf, fn)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = false
  if not ok then
    error(err)
  end
end

local function shorten(s, n)
  s = (s or ""):gsub("%s+", " ")
  return #s > n and (s:sub(1, n - 1) .. "…") or s
end

--- Ожидающие сообщения показываются виртуальными строками под последней строкой чата.
local function render_queue(st)
  if not vim.api.nvim_buf_is_valid(st.chat_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(st.chat_buf, ns_queue, 0, -1)
  local q = st.session.queue
  if #q == 0 then
    return
  end
  local virt = {}
  for i, text in ipairs(q) do
    virt[#virt + 1] = { { ("⏳ %d. %s"):format(i, shorten(text, 70)), "AquaAIQueued" } }
  end
  pcall(vim.api.nvim_buf_set_extmark, st.chat_buf, ns_queue, vim.api.nvim_buf_line_count(st.chat_buf) - 1, 0, { virt_lines = virt })
end

local function should_follow(st)
  if not valid(st.chat_win) then
    return false
  end
  if vim.api.nvim_get_current_win() ~= st.chat_win then
    return true
  end
  return vim.api.nvim_win_get_cursor(st.chat_win)[1] >= vim.api.nvim_buf_line_count(st.chat_buf) - 1
end

local function scroll(st)
  if valid(st.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, st.chat_win, { vim.api.nvim_buf_line_count(st.chat_buf), 0 })
  end
end

--- Добавить блок строк (с подсветкой) в конец. Возвращает индекс (0-based) первой строки.
---@param st aqua.ai.UI
---@param lines string[]
---@param hl? string  подсветка первой строки
local function add_lines(st, lines, hl)
  local follow = should_follow(st)
  local buf, first = st.chat_buf, 0
  mod(buf, function()
    local n = vim.api.nvim_buf_line_count(buf)
    local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
    if last ~= "" then
      vim.api.nvim_buf_set_lines(buf, n, n, false, { "" })
      n = n + 1
    end
    first = n - 1
    local block = vim.list_extend(vim.deepcopy(lines), { "" })
    vim.api.nvim_buf_set_lines(buf, n - 1, n, false, block)
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns, first, 0, { line_hl_group = hl, priority = 50 })
    end
  end)
  render_queue(st)
  if follow then scroll(st) end
  return first
end

--- Дописать текст в конец (потоковый вывод).
---@param st aqua.ai.UI
---@param text string
local function append_text(st, text)
  local follow = should_follow(st)
  local buf = st.chat_buf
  mod(buf, function()
    local n = vim.api.nvim_buf_line_count(buf)
    local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
    vim.api.nvim_buf_set_text(buf, n - 1, #last, n - 1, #last, vim.split(text, "\n", { plain = true }))
  end)
  render_queue(st)
  if follow then scroll(st) end
end

local function end_stream(st)
  local buf = st.chat_buf
  local n = vim.api.nvim_buf_line_count(buf)
  local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
  if last ~= "" then
    mod(buf, function() vim.api.nvim_buf_set_lines(buf, n, n, false, { "" }) end)
  end
end

-- ── События сессии → интерфейс ──────────────────────────────────────────────

local TOOL_ICON = { read = "󰈈", write = "󰏫", delete = "󰆴", web = "󰖟" }

local function welcome(st)
  local profile = config.profile()
  add_lines(st, {
    "# 🌊 Aqua AI",
    "",
    ("Модель: **%s** (%s) · проект: `%s`"):format(profile.model or "не выбрана — /model", profile.name, vim.fn.fnamemodify(st.root, ":~")),
    "",
    "Я могу читать и менять файлы проекта, создавать папки, искать в интернете и править Markdown.",
    "Каждое изменение показывается вам для подтверждения (`y` — да, `a` — всегда в этой сессии, `n` — нет).",
    "",
    "`/new` · `/model` · `/profile` · `/yolo` · `/tools` · `/help` · `Ctrl-C` — прервать",
  })
end

function M.on_event(st, ev, a, b, c, d)
  if ev == "user" then
    local lines = { "", "## 󰭹 Вы" }
    vim.list_extend(lines, vim.split(a, "\n", { plain = true }))
    local row = add_lines(st, lines)
    vim.api.nvim_buf_set_extmark(st.chat_buf, ns, row + 1, 0, { line_hl_group = "AquaAIUser", priority = 50 })
  elseif ev == "assistant_start" then
    local row = add_lines(st, { "", ("## 🌊 Aqua · %s"):format(a and a.model or "?") })
    vim.api.nvim_buf_set_extmark(st.chat_buf, ns, row + 1, 0, { line_hl_group = "AquaAIBot", priority = 50 })
    st.streaming = true
  elseif ev == "text" then
    append_text(st, a)
  elseif ev == "assistant_end" then
    st.streaming = false
    end_stream(st)
  elseif ev == "tool_start" then
    -- a = call, b = summary, c = category
    local row = add_lines(st, { ("> %s `%s` %s"):format(TOOL_ICON[c] or "󰠱", a.name, shorten(b, 90)) }, "AquaAITool")
    st.tool_lines[a.id] = row
  elseif ev == "tool_end" then
    -- a = call, b = result, c = is_err, d = denied
    local row = st.tool_lines[a.id]
    if row then
      local mark = d and " ⛔ отклонено" or (c and (" ✗ " .. shorten(b, 100)) or (" ✓ " .. shorten(b:match("^[^\n]*"), 80)))
      mod(st.chat_buf, function()
        local line = vim.api.nvim_buf_get_lines(st.chat_buf, row, row + 1, false)[1] or ""
        vim.api.nvim_buf_set_text(st.chat_buf, row, #line, row, #line, { mark })
        vim.api.nvim_buf_set_extmark(st.chat_buf, ns, row, 0, { line_hl_group = (c and not d) and "AquaAIErr" or "AquaAITool", priority = 60 })
      end)
    end
  elseif ev == "error" then
    add_lines(st, { "> ⚠ " .. a }, "AquaAIErr")
  elseif ev == "status" then
    M.set_status(st, a)
  elseif ev == "done" then
    if a then
      add_lines(st, { "> ⏹ прервано" }, "AquaAITool")
    end
  elseif ev == "queue" then
    render_queue(st)
    if valid(st.input_win) then
      vim.cmd("redrawstatus!")
    end
  elseif ev == "reset" then
    mod(st.chat_buf, function() vim.api.nvim_buf_set_lines(st.chat_buf, 0, -1, false, { "" }) end)
    vim.api.nvim_buf_clear_namespace(st.chat_buf, ns, 0, -1)
    st.tool_lines = {}
    welcome(st)
  elseif ev == "need_model" then
    vim.schedule(function()
      require("aqua.ai").select_model(function(ok)
        if ok then st.session:send(a) end
      end)
    end)
  end
end

--- Восстановить переписку из сохранённой истории.
local function replay(st)
  for _, m in ipairs(st.session.messages) do
    if m.role == "user" then
      M.on_event(st, "user", m.content)
    elseif m.role == "assistant" then
      M.on_event(st, "assistant_start", config.profile())
      if m.content and m.content ~= "" then
        append_text(st, m.content)
      end
      M.on_event(st, "assistant_end", m)
      for _, call in ipairs(m.tool_calls or {}) do
        local tool = require("aqua.ai.tools").get(call.name)
        M.on_event(st, "tool_start", call, require("aqua.ai.tools").summary(call.name, call.args), tool and tool.category or "read")
      end
    elseif m.role == "tool" then
      M.on_event(st, "tool_end", { id = m.tool_call_id }, m.content, m.content:match("^Пользователь отклонил") ~= nil, m.content:match("^Пользователь отклонил") ~= nil)
    end
  end
end

-- ── Статус и winbar ─────────────────────────────────────────────────────────

local function stop_timer(st)
  if st.timer then
    st.timer:stop()
    st.timer:close()
    st.timer = nil
  end
end

function M.set_status(st, status)
  st.status = status
  if status == "idle" then
    stop_timer(st)
  elseif not st.timer then
    st.timer = assert((vim.uv or vim.loop).new_timer())
    st.timer:start(0, 120, vim.schedule_wrap(function()
      st.spinner = (st.spinner % #SPINNER) + 1
      if valid(st.chat_win) then
        vim.cmd("redrawstatus!")
      end
    end))
  end
  if valid(st.chat_win) then
    vim.cmd("redrawstatus!")
  end
end

local function esc(s)
  return (tostring(s):gsub("%%", "%%%%"))
end

--- Выражение для 'winbar' окна чата.
function M.winbar()
  local win = vim.g.statusline_winid
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return ""
  end
  local st = M.states[vim.b[vim.api.nvim_win_get_buf(win)].aqua_ai_root or ""]
  if not st then
    return ""
  end
  local profile = config.profile()
  local text = ("%%#AquaAIBar# %s Aqua AI %%#AquaAIInfo# %s · %s "):format(ICON, esc(profile.model or "модель не выбрана"), esc(profile.name))
  local s = st.status
  local spin = SPINNER[st.spinner] or SPINNER[1]
  local right
  if s == "thinking" then
    right = spin .. " думает"
  elseif s == "approval" then
    right = "⏸ ждёт подтверждения"
  elseif s:match("^tool:") then
    right = spin .. " " .. esc(s:sub(6))
  else
    right = ""
  end
  if st.session.yolo then
    right = "⚡ YOLO  " .. right
  end
  return text .. "%=%#AquaAIStatus#" .. right .. " "
end

--- Подсказка над полем ввода (+ число сообщений в очереди).
function M.input_bar()
  local win = vim.g.statusline_winid
  local st = win and vim.api.nvim_win_is_valid(win) and M.states[vim.b[vim.api.nvim_win_get_buf(win)].aqua_ai_root or ""]
  local n = st and #st.session.queue or 0
  if st and st.esc_until and (vim.uv or vim.loop).now() < st.esc_until then
    return "%#AquaAIStatus# Esc ещё раз — очистить ввод"
  end
  if st and st.session.running and n == 0 then
    return "%#AquaAIHint# 󰌑 Enter — в очередь  ·  Esc — стоп"
  end
  if n > 0 then
    return "%#AquaAIStatus# ⏳ в очереди: " .. n .. "%#AquaAIHint#  ·  Ctrl-C — стоп и очистить"
  end
  return "%#AquaAIHint# 󰌑 Enter — отправить  ·  ⇧Enter — строка  ·  Esc — стоп"
end

-- ── Окна ────────────────────────────────────────────────────────────────────

local function scratch(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = ft
  vim.b[buf].completion = false
  vim.b[buf].snacks_indent = false
  vim.b[buf].snacks_scroll = false
  return buf
end

function M.visible_state()
  for _, st in pairs(M.states) do
    if valid(st.chat_win) then
      return st
    end
  end
end

function M.focus_input(st, insert)
  if valid(st.input_win) then
    vim.api.nvim_set_current_win(st.input_win)
    if insert ~= false then
      vim.cmd.startinsert({ bang = true })
    end
  end
end

---@param st aqua.ai.UI
function M.hide(st)
  for _, w in ipairs({ st.input_win, st.chat_win }) do
    if valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  st.chat_win, st.input_win = nil, nil
end

function M.hide_all()
  for _, st in pairs(M.states) do
    M.hide(st)
  end
end

local function input_text(st)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(st.input_buf, 0, -1, false), "\n"))
end

local function set_input(st, text)
  vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

--- Разбор слэш-команд из поля ввода. Возвращает true, если это команда.
local SLASH = {
  new = "new_chat", clear = "new_chat", model = "select_model", profile = "select_profile",
  yolo = "toggle_yolo", stop = "cancel", cancel = "cancel", tools = "tools_info", help = "help",
}
local function slash(text)
  local cmd, rest = text:match("^/(%w+)%s*(.*)$")
  local fn = cmd and SLASH[cmd]
  if not fn then
    return false
  end
  vim.schedule(function()
    local ai = require("aqua.ai")
    if cmd == "model" and rest ~= "" then
      return ai.set_model(rest)
    end
    ai[fn]()
  end)
  return true
end

function M.submit(st)
  local text = input_text(st)
  if text == "" then
    return
  end
  if slash(text) then
    set_input(st, "")
    return
  end
  -- Пока модель отвечает, сообщение встаёт в очередь (session:send) — поле ввода всегда свободно
  st.history[#st.history + 1] = text
  st.hist_idx = nil
  set_input(st, "")
  local ok, err = st.session:send(text)
  if not ok then
    set_input(st, text) -- не теряем набранное
    vim.notify(err, vim.log.levels.WARN, { title = "Aqua AI" })
  end
  -- сразу можно писать следующее
  if valid(st.input_win) and vim.api.nvim_get_current_win() == st.input_win then
    vim.cmd.startinsert({ bang = true })
  end
end

--- Enter: отправка. В режиме вставки строка, оканчивающаяся на `\`, переносится (запасной способ
--- для терминалов, которые не отличают Shift+Enter от Enter).
function M.enter(st, insert)
  if insert == nil then
    insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
  end
  if insert then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(st.input_buf, row - 1, row, false)[1] or ""
    if line:sub(-1) == "\\" then
      vim.api.nvim_buf_set_lines(st.input_buf, row - 1, row, false, { line:sub(1, -2), "" })
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return
    end
  end
  M.submit(st)
end

--- Esc, как в Claude Code: останавливает ответ модели; в пустом состоянии — «Esc ещё раз» очищает ввод.
function M.esc(st)
  if st.session.running then
    local queued = #st.session.queue
    st.session:cancel()
    if queued > 0 then
      vim.notify(("Прервано. Очередь очищена (сообщений: %d)"):format(queued), vim.log.levels.WARN, { title = "Aqua AI" })
    end
    return
  end
  if input_text(st) == "" then
    return
  end
  local now = (vim.uv or vim.loop).now()
  if st.esc_until and now < st.esc_until then
    st.esc_until = nil
    set_input(st, "")
  else
    st.esc_until = now + 800
    vim.defer_fn(function()
      if valid(st.input_win) then vim.cmd("redrawstatus!") end
    end, 850)
  end
  vim.cmd("redrawstatus!")
end

--- Ctrl-C: останавливает ответ; когда модель молчит — очищает поле ввода.
function M.ctrl_c(st)
  if st.session.running then
    return M.esc(st)
  end
  set_input(st, "")
end

local function recall(st, dir)
  if #st.history == 0 then return end
  local idx = (st.hist_idx or (#st.history + 1)) + dir
  idx = math.max(1, math.min(#st.history + 1, idx))
  st.hist_idx = idx
  set_input(st, st.history[idx] or "")
  vim.cmd("normal! G$")
end

local function setup_keys(st)
  local function map(buf, mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = "Aqua AI: " .. desc })
  end
  local ai = function() return require("aqua.ai") end
  -- поле ввода
  local ib = st.input_buf
  -- Enter отправляет в обоих режимах (поле ввода открывается в режиме вставки);
  -- новая строка — Ctrl-J / Shift-Enter / Alt-Enter
  map(ib, { "n", "i" }, "<CR>", function() M.enter(st) end, "отправить")
  map(ib, { "n", "i" }, "<C-s>", function() M.submit(st) end, "отправить")
  for _, key in ipairs({ "<C-j>", "<S-CR>", "<M-CR>" }) do
    vim.keymap.set("i", key, "<CR>", { buffer = ib, noremap = true, silent = true, desc = "Aqua AI: новая строка" })
  end
  map(ib, { "n", "i" }, "<C-c>", function() M.ctrl_c(st) end, "стоп / очистить ввод")
  map(ib, "n", "q", function() M.hide(st) end, "скрыть")
  map(ib, { "n", "i" }, "<C-,>", function() M.hide(st) end, "скрыть")
  map(ib, { "i", "n" }, "<C-p>", function() recall(st, -1) end, "предыдущий запрос")
  map(ib, { "i", "n" }, "<C-n>", function() recall(st, 1) end, "следующий запрос")
  -- стрелки листают историю, когда курсор на первой / последней строке
  map(ib, { "i", "n" }, "<Up>", function()
    if vim.api.nvim_win_get_cursor(0)[1] == 1 then recall(st, -1) else vim.api.nvim_feedkeys(vim.keycode("<Up>"), "n", false) end
  end, "вверх / история")
  map(ib, { "i", "n" }, "<Down>", function()
    if vim.api.nvim_win_get_cursor(0)[1] == vim.api.nvim_buf_line_count(ib) then recall(st, 1) else vim.api.nvim_feedkeys(vim.keycode("<Down>"), "n", false) end
  end, "вниз / история")
  -- Поле ввода как в Claude Code CLI: всегда режим вставки, привычные readline-клавиши
  if not config.get().input_vim_mode then
    map(ib, "i", "<Esc>", function() M.esc(st) end, "стоп / очистить ввод")
    local function emacs(lhs, rhs, desc)
      vim.keymap.set("i", lhs, rhs, { buffer = ib, noremap = true, silent = true, desc = "Aqua AI: " .. desc })
    end
    emacs("<C-a>", "<Home>", "начало строки")
    emacs("<C-e>", "<End>", "конец строки")
    emacs("<C-b>", "<Left>", "символ влево")
    emacs("<C-f>", "<Right>", "символ вправо")
    emacs("<M-b>", "<C-Left>", "слово влево")
    emacs("<M-f>", "<C-Right>", "слово вправо")
    emacs("<C-k>", "<C-o>D", "удалить до конца строки")
    emacs("<M-BS>", "<C-w>", "удалить слово")
  end
  -- окно переписки
  local cb = st.chat_buf
  map(cb, "n", "q", function() M.hide(st) end, "скрыть")
  map(cb, { "n", "t" }, "<C-,>", function() M.hide(st) end, "скрыть")
  map(cb, "n", "<C-c>", function() ai().cancel() end, "прервать")
  for _, k in ipairs({ "i", "a", "o", "<CR>" }) do
    map(cb, "n", k, function() M.focus_input(st) end, "перейти к вводу")
  end
  map(cb, "n", "]]", function() vim.fn.search("^## ", "W") end, "следующее сообщение")
  map(cb, "n", "[[", function() vim.fn.search("^## ", "bW") end, "предыдущее сообщение")
end

local function new_state(root)
  ---@type aqua.ai.UI
  local st = {
    root = root,
    session = session_mod.get(root),
    chat_buf = scratch("aqua-ai://chat/" .. root, "markdown"),
    input_buf = scratch("aqua-ai://input/" .. root, "aqua_ai_input"),
    status = "idle",
    tool_lines = {},
    history = {},
    spinner = 1,
  }
  vim.b[st.chat_buf].aqua_ai_root = root
  vim.b[st.input_buf].aqua_ai_root = root
  vim.bo[st.chat_buf].modifiable = false
  vim.api.nvim_buf_set_lines(st.input_buf, 0, -1, false, { "" })
  setup_keys(st)
  M.setup_input(st)
  -- поле ввода растёт вместе с текстом (Shift+Enter), но не больше 14 строк
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = st.input_buf,
    callback = function()
      if valid(st.input_win) then
        local min = config.get().input_height
        local h = math.max(min, math.min(14, vim.api.nvim_buf_line_count(st.input_buf) + 1))
        if vim.api.nvim_win_get_height(st.input_win) ~= h then
          pcall(vim.api.nvim_win_set_height, st.input_win, h)
        end
      end
    end,
  })
  st.session.cb = function(ev, ...) M.on_event(st, ev, ...) end
  M.states[root] = st
  welcome(st)
  replay(st)
  return st
end

--- Поведение поля ввода: обычное текстовое поле, а не редактор Vim.
function M.setup_input(st)
  local buf = st.input_buf
  vim.b[buf].minipairs_disable = true -- без автозакрытия скобок и кавычек в чате
  vim.bo[buf].autoindent, vim.bo[buf].smartindent, vim.bo[buf].expandtab = false, false, true
  vim.bo[buf].textwidth, vim.bo[buf].formatoptions, vim.bo[buf].comments = 0, "", ""
  local group = vim.api.nvim_create_augroup("aqua_ai_input_" .. buf, { clear = true })

  -- Клик/переход в окно переписки и попытка печатать → печатаем в поле ввода
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = st.chat_buf,
    callback = function()
      vim.schedule(function()
        vim.cmd.stopinsert()
        M.focus_input(st)
      end)
    end,
  })

  if config.get().input_vim_mode then
    return
  end
  local function insert_here()
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
        vim.cmd.startinsert({ bang = true })
      end
    end)
  end
  -- Любой вход в поле ввода (клик мышью, возврат из окна подтверждения, <C-w>w) — сразу режим вставки,
  -- а выход из режима вставки (Esc, <C-\\><C-n>) возвращает в него обратно.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, { group = group, buffer = buf, callback = insert_here })
  vim.api.nvim_create_autocmd("InsertLeave", { group = group, buffer = buf, callback = insert_here })
end

---@param root string
function M.state(root)
  return M.states[root] or new_state(root)
end

local function window_opts(win, extra)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  wo.foldcolumn, wo.cursorline, wo.list, wo.spell = "0", false, false, false
  wo.statuscolumn = ""
  wo.wrap, wo.linebreak, wo.breakindent = true, true, true
  wo.winfixwidth = true
  for k, v in pairs(extra or {}) do
    wo[k] = v
  end
end

---@param st aqua.ai.UI
local function open_windows(st)
  local cfg = config.get()
  vim.cmd("botright vsplit")
  st.chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.chat_win, st.chat_buf)
  vim.api.nvim_win_set_width(st.chat_win, math.max(40, math.floor(vim.o.columns * cfg.width)))
  window_opts(st.chat_win, {
    conceallevel = 2,
    concealcursor = "nc",
    winbar = "%!v:lua.require'aqua.ai.ui'.winbar()",
    winhighlight = "Normal:AquaAINormal,NormalNC:AquaAINormal,WinBar:AquaAIBar,WinBarNC:AquaAIBar",
  })
  vim.cmd("belowright split")
  st.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(st.input_win, st.input_buf)
  vim.api.nvim_win_set_height(st.input_win, cfg.input_height)
  window_opts(st.input_win, {
    winfixheight = true,
    winbar = "%!v:lua.require'aqua.ai.ui'.input_bar()",
    winhighlight = "Normal:AquaAIInput,NormalNC:AquaAIInput,WinBar:AquaAIHint,WinBarNC:AquaAIHint",
  })
  vim.api.nvim_buf_call(st.chat_buf, function() end)
  scroll(st)
end

--- Открыть чат проекта (или сфокусировать, если уже открыт).
---@param root string
function M.open(root)
  local cur = M.visible_state()
  if cur and cur.root == root then
    M.focus_input(cur)
    return cur
  end
  if cur then
    M.hide(cur)
  end
  -- Агенты в терминале (Claude) занимают то же место справа
  local ok, agent = pcall(require, "aqua.agent")
  if ok then
    for _, a in pairs(agent.agents) do
      a.hide_all()
    end
  end
  local st = M.state(root)
  open_windows(st)
  M.focus_input(st)
  return st
end

--- Показать / скрыть.
---@param root string
function M.toggle(root)
  local cur = M.visible_state()
  if cur and cur.root == root then
    M.hide(cur)
    return
  end
  return M.open(root)
end

--- Дописать текст в поле ввода (файл, выделение, диагностика) и перейти к вводу.
---@param st aqua.ai.UI
---@param text string
function M.add_to_input(st, text)
  local buf = st.input_buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local existing = table.concat(lines, "\n")
  local new = existing == "" and text or (existing .. (existing:match("%s$") and "" or "\n") .. text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(new, "\n", { plain = true }))
  M.focus_input(st)
  if valid(st.input_win) then
    pcall(vim.api.nvim_win_set_cursor, st.input_win, { vim.api.nvim_buf_line_count(buf), 0 })
    vim.cmd("normal! $")
  end
end

--- Открыть файл в обычном окне редактора (не в окне чата).
---@param abs string
---@param line? integer
function M.open_in_editor(abs, line)
  local target
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative == "" and vim.bo[b].buftype == "" then
      target = w
      break
    end
  end
  if not target then
    return vim.cmd("topleft vsplit " .. vim.fn.fnameescape(abs))
  end
  vim.api.nvim_win_call(target, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    if line then
      pcall(vim.api.nvim_win_set_cursor, target, { line, 0 })
      vim.cmd("normal! zz")
    end
  end)
end

--- Для статусной строки.
function M.statusline()
  local any = next(M.states) ~= nil
  if not any then
    return ""
  end
  for _, st in pairs(M.states) do
    if st.status ~= "idle" then
      return ICON .. " " .. SPINNER[st.spinner]
    end
  end
  return M.visible_state() and (ICON .. " ") or ""
end

return M
