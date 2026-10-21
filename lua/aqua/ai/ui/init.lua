-- Чат Aqua AI — терминал внутри Neovim, как Claude Code.
--
-- Одно окно справа: переписка и поле ввода нарисованы внутри терминального буфера
-- (nvim_open_term), поэтому работают привычные клавиши терминала:
--   Ctrl-, / q (в Normal)     — скрыть чат целиком (процесс и переписка остаются)
--   Ctrl-H / Ctrl-K / Ctrl-W… — перейти в другое окно прямо из режима ввода
--   Esc                        — остановить ответ модели · Esc Esc — режим Normal (прокрутка, копирование)
-- Готовые сообщения печатаются в терминал один раз (остаются в истории прокрутки),
-- а нижняя «живая» часть — потоковый ответ, инструменты, статус, рамка ввода — перерисовывается.
local config = require("aqua.ai.config")
local session_mod = require("aqua.ai.session")
local render = require("aqua.ai.ui.render")
local editor = require("aqua.ai.ui.editor")

local M = {}

---@class aqua.ai.UI
---@field root string
---@field session aqua.ai.Session
---@field buf? integer терминальный буфер
---@field chan? integer
---@field win? integer
---@field width integer ширина, под которую отрисован текст
---@field blocks table[] готовые блоки переписки (для перерисовки при смене ширины)
---@field live? table потоковый ответ модели
---@field pending table[] инструменты, которые ещё выполняются
---@field out string[] готовые строки, ещё не отправленные в терминал
---@field dyn integer строк от начала «живой» части до курсора
---@field ed aqua.ai.Editor
---@field dec aqua.ai.Decoder
---@field status string

---@type table<string, aqua.ai.UI>
M.states = {}

local uv = vim.uv or vim.loop
local seg = render.seg
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ICON = "\u{f06a9}"
local TOOL_ICON = { read = "󰈈", write = "󰏫", delete = "󰆴", web = "󰖟", docs = "\u{f02d}", exec = "\u{f120}" }

M.commands = {
  { "new", "новый чат" },
  { "model", "выбрать модель (/model имя — сразу)" },
  { "profile", "профиль модели (сервер)" },
  { "stack", "стек проекта" },
  { "research", "заново изучить документацию версий" },
  { "knowledge", "сохранённые заметки о версиях" },
  { "yolo", "без подтверждений: вкл / выкл" },
  { "tools", "инструменты и права" },
  { "stop", "прервать ответ" },
  { "clear", "новый чат" },
  { "help", "клавиши и команды" },
  { "exit", "закрыть окно чата (разговор сохраняется)" },
}
local SLASH = {
  new = "new_chat", clear = "new_chat", model = "select_model", profile = "select_profile",
  stack = "show_stack", research = "research", knowledge = "knowledge_picker",
  yolo = "toggle_yolo", stop = "cancel", cancel = "cancel", tools = "tools_info",
}

local function valid_win(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function valid_buf(b)
  return b ~= nil and vim.api.nvim_buf_is_valid(b)
end

local function shorten(s, n)
  s = (s or ""):gsub("%s+", " ")
  return render.cut(s, n)
end

local function blank()
  return { segs = {}, w = 0 }
end

-- ── Блоки переписки → строки экрана ─────────────────────────────────────────

local function banner_rows(st, W)
  local profile = config.profile()
  local rows = render.box({
    { seg("󰖌 ", "AquaAIBot"), seg("Aqua AI", "AquaAITitle"), seg("  · агент на вашей модели", "AquaAIDim") },
    {},
    { seg("  модель  ", "AquaAIDim"), seg(profile.model or "не выбрана — /model", "AquaAIText"), seg(" · " .. profile.name, "AquaAIDim") },
    { seg("  проект  ", "AquaAIDim"), seg(vim.fn.fnamemodify(st.root, ":~"), "AquaAIText") },
  }, W, "AquaAIBoxDim")
  rows[#rows + 1] = blank()
  local pad = { seg("  ") }
  vim.list_extend(rows, render.wrap({ seg("Читаю и меняю файлы проекта, ищу в интернете и изучаю документацию версий вашего стека. Каждое изменение — с вашего подтверждения.", "AquaAIMuted") }, W, { first = pad, rest = pad }))
  vim.list_extend(rows, render.wrap({
    seg("/", "AquaAICmd"), seg(" команды · ", "AquaAIDim"), seg("@путь", "AquaAICmd"), seg(" файл в контекст · ", "AquaAIDim"),
    seg("Esc Esc", "AquaAICmd"), seg(" прокрутка · ", "AquaAIDim"), seg("Ctrl-,", "AquaAICmd"), seg(" скрыть", "AquaAIDim"),
  }, W, { first = pad, rest = pad }))
  return rows
end

local function user_rows(text, W)
  local rows = { blank() }
  for i, line in ipairs(vim.split(render.sanitize(text), "\n", { plain = true })) do
    vim.list_extend(rows, render.wrap({ seg(line, "AquaAIUserText") }, W, {
      first = { i == 1 and seg("❯ ", "AquaAIUserMark") or seg("  ", "AquaAIUserText") },
      rest = { seg("  ", "AquaAIUserText") },
      fill = "AquaAIUserBg",
      keep_lead = true,
    }))
  end
  return rows
end

--- Строки ответа модели начиная с b.done; final — дорисовать и незаконченную строку.
---@param b table { text, done, md, started }
local function assistant_rows(b, W, final)
  local rows = {}
  local function line_rows(line)
    if not b.started and vim.trim(line) == "" then
      return
    end
    local r = render.markdown_line(line, b.md, W - 2)
    if #r == 0 then
      return
    end
    if not b.started then
      rows[#rows + 1] = blank()
    end
    render.indent(r, b.started and { seg("  ") } or { seg("● ", "AquaAIBot") }, { seg("  ") })
    b.started = true
    vim.list_extend(rows, r)
  end
  while true do
    local nl = b.text:find("\n", b.done + 1, true)
    if not nl then
      break
    end
    line_rows(b.text:sub(b.done + 1, nl - 1))
    b.done = nl
  end
  if final and b.done < #b.text then
    line_rows(b.text:sub(b.done + 1))
    b.done = #b.text
  end
  return rows
end

local function tool_rows(b, W, spin)
  local hl = not b.finished and "AquaAISpinner" or (b.denied and "AquaAIWarn" or (b.err and "AquaAIErr" or "AquaAIOk"))
  local icon = b.finished and (TOOL_ICON[b.category] or "󰠱") or spin
  local rows = { blank() }
  vim.list_extend(rows, render.wrap({ seg(b.name, "AquaAIToolName"), seg(" " .. b.summary, "AquaAIMuted") }, W, {
    first = { seg(icon .. " ", hl) },
    rest = { seg("  ") },
  }))
  if b.finished then
    local text = b.denied and "отклонено" or (b.err and shorten(b.result, 300) or shorten((b.result or ""):match("^[^\n]*"), 160))
    local mark = b.denied and "⛔ " or (b.err and "✗ " or "✓ ")
    vim.list_extend(rows, render.wrap({ seg(mark, hl), seg(text, b.err and not b.denied and "AquaAIErr" or "AquaAIMuted") }, W, {
      first = { seg("  ⎿  ", "AquaAIDim") },
      rest = { seg("     ") },
    }))
  end
  return rows
end

local NOTE = {
  error = { "⚠ ", "AquaAIErr" },
  notice = { "↻ ", "AquaAIMuted" },
  stop = { "⏹ ", "AquaAIWarn" },
}

local function block_rows(st, b, W)
  if b.kind == "banner" then
    return banner_rows(st, W)
  elseif b.kind == "user" then
    return user_rows(b.text, W)
  elseif b.kind == "assistant" then
    return assistant_rows({ text = b.text, done = 0, md = {}, started = false }, W, true)
  elseif b.kind == "tool" then
    return tool_rows(b, W)
  elseif b.kind == "info" then
    local rows = { blank() }
    return vim.list_extend(rows, render.indent(render.markdown(b.text, W - 2), { seg("  ") }, { seg("  ") }))
  end
  local mark, hl = unpack(NOTE[b.kind] or NOTE.notice)
  local rows = { blank() }
  for i, line in ipairs(vim.split(b.text, "\n", { plain = true })) do
    vim.list_extend(rows, render.wrap({ seg(line, hl) }, W, { first = { seg(i == 1 and mark or "  ", hl) }, rest = { seg("  ") } }))
  end
  return rows
end
M._block_rows = block_rows

-- ── «Живая» часть: потоковый ответ, инструменты, статус, ввод ───────────────

local function height(st)
  return valid_win(st.win) and vim.api.nvim_win_get_height(st.win) or 24
end

local function status_rows(st, W)
  local s = st.status
  local text
  if s == "thinking" then
    text = "Думаю…"
  elseif s == "approval" then
    text = "Жду вашего решения в окне подтверждения"
  elseif s:match("^tool:") then
    text = "Выполняю " .. s:sub(6) .. "…"
  elseif s:match("^research:") then
    text = "Изучаю документацию " .. s:sub(10) .. "…"
  else
    text = s
  end
  local secs = st.since and math.floor((uv.now() - st.since) / 1000) or 0
  local icon = s == "approval" and "⏸" or SPINNER[st.spinner]
  return render.wrap({
    seg(icon .. " ", "AquaAISpinner"),
    seg(text, "AquaAIStatusText"),
    seg(("  (%d с · esc — прервать)"):format(secs), "AquaAIDim"),
  }, W)
end

local function hint_rows(st, W)
  local cmd = st.ed.text:match("^/(%w*)$")
  if cmd then
    local rows = {}
    for _, c in ipairs(M.commands) do
      if c[1]:sub(1, #cmd) == cmd then
        local name = "  /" .. c[1]
        rows[#rows + 1] = { segs = { seg(name, "AquaAICmd"), seg("  " .. render.cut(c[2], math.max(4, W - #name - 2)), "AquaAIDim") }, w = 0 }
      end
    end
    if #rows > 0 then
      for _, r in ipairs(rows) do
        r.w = render.width(render.plain(r))
      end
      return rows
    end
  end
  local profile = config.profile()
  local left = st.session.running and "⏎ в очередь · ⇧⏎ строка · esc стоп" or "⏎ отправить · ⇧⏎ строка · / команды"
  local right = (st.session.yolo and "⚡ YOLO · " or "") .. (profile.model or "модель не выбрана")
  left = "  " .. left
  local lw, rw = render.width(left), render.width(right)
  if lw + rw + 2 > W then
    right, rw = "", 0
    left = render.cut(left, W)
    lw = render.width(left)
  end
  return { {
    segs = { seg(left, "AquaAIHintText"), seg(string.rep(" ", math.max(0, W - lw - rw)), "AquaAIHintText"), seg(right, st.session.yolo and "AquaAIWarn" or "AquaAIDim") },
    w = lw + math.max(0, W - lw - rw) + rw,
  } }
end

---@return table[] rows, integer cursor_row, integer cursor_col
local function dynamic_rows(st)
  local W = st.width
  local rows = {}
  if st.live then
    local b = st.live
    rows = assistant_rows({ text = b.text, done = b.done, md = vim.deepcopy(b.md), started = b.started }, W, true)
  end
  local spin = SPINNER[st.spinner]
  for _, b in ipairs(st.pending) do
    vim.list_extend(rows, tool_rows(b, W, spin))
  end
  if st.status ~= "idle" then
    rows[#rows + 1] = blank()
    vim.list_extend(rows, status_rows(st, W))
  end
  local q = st.session.queue
  if #q > 0 then
    rows[#rows + 1] = blank()
    for i, text in ipairs(q) do
      if i > 3 then
        rows[#rows + 1] = { segs = { seg(("   … и ещё %d"):format(#q - 3), "AquaAIQueued") }, w = 0 }
        break
      end
      local t = ("⏳ %s"):format(shorten(text, W - 4))
      rows[#rows + 1] = { segs = { seg(t, "AquaAIQueued") }, w = render.width(t) }
    end
  end
  rows[#rows + 1] = blank()
  local box, crow, ccol = render.input_box(st.ed.text, st.ed.cur, W, {
    placeholder = st.session.running and "Можно писать дальше — сообщение встанет в очередь" or "Спросите что-нибудь или попросите изменить код…",
    border = st.session.running and "AquaAIBoxBusy" or "AquaAIBox",
    max_rows = math.max(3, math.min(10, math.floor(height(st) / 3))),
  })
  local box_at = #rows
  vim.list_extend(rows, box)
  vim.list_extend(rows, hint_rows(st, W))
  -- не больше высоты окна: сверху отрезается начало потокового ответа (целиком он
  -- напечатается, как только строка закончится)
  local max = math.max(5, height(st) - 1)
  if #rows > max then
    local drop = #rows - max
    rows = vim.list_slice(rows, drop + 1)
    box_at = box_at - drop
  end
  return rows, math.max(1, box_at + crow), ccol
end

--- Отправить готовые строки и перерисовать «живую» часть.
local function draw(st)
  st.draw_pending = false
  if not (st.chan and valid_buf(st.buf)) then
    st.out = {}
    return
  end
  local out = {}
  if st.dyn > 0 then
    out[#out + 1] = ("\27[%dA"):format(st.dyn)
  end
  out[#out + 1] = "\r\27[J"
  for _, line in ipairs(st.out) do
    out[#out + 1] = line .. "\r\n"
  end
  st.out = {}
  local rows, crow, ccol = dynamic_rows(st)
  out[#out + 1] = table.concat(render.to_ansi(rows, st.width), "\r\n")
  local up = #rows - crow
  if up > 0 then
    out[#out + 1] = ("\27[%dA"):format(up)
  end
  out[#out + 1] = ("\27[%dG"):format(ccol + 1)
  st.dyn = crow - 1
  pcall(vim.api.nvim_chan_send, st.chan, table.concat(out))
end
M._draw = draw

local function schedule_draw(st)
  if st.draw_pending then
    return
  end
  st.draw_pending = true
  vim.defer_fn(function()
    if st.draw_pending then
      draw(st)
    end
  end, 16)
end

--- Готовые строки → в очередь вывода.
local function emit(st, rows)
  if st.replaying or not st.chan or #rows == 0 then
    return
  end
  vim.list_extend(st.out, render.to_ansi(rows, st.width))
  schedule_draw(st)
end

local function add_block(st, b)
  st.blocks[#st.blocks + 1] = b
  emit(st, block_rows(st, b, st.width))
end

local function commit_pending(st)
  while st.pending[1] and st.pending[1].finished do
    local b = table.remove(st.pending, 1)
    st.blocks[#st.blocks + 1] = b
    emit(st, tool_rows(b, st.width))
  end
end

local function finish_live(st)
  local b = st.live
  if not b then
    return
  end
  st.live = nil
  if st.chan and not st.replaying then
    emit(st, assistant_rows(b, st.width, true))
  end
  if not b.text:match("%S") then
    for i = #st.blocks, 1, -1 do
      if st.blocks[i] == b then
        table.remove(st.blocks, i)
        break
      end
    end
  end
end

-- ── Статус ──────────────────────────────────────────────────────────────────

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
    st.since = nil
  else
    st.since = st.since or uv.now()
    if not st.timer then
      st.timer = assert(uv.new_timer())
      st.timer:start(100, 100, vim.schedule_wrap(function()
        st.spinner = (st.spinner % #SPINNER) + 1
        if valid_win(st.win) then
          schedule_draw(st)
        end
      end))
    end
  end
  schedule_draw(st)
  if valid_win(st.win) then
    vim.cmd("redrawstatus!")
  end
end

-- ── События сессии ──────────────────────────────────────────────────────────

function M.on_event(st, ev, a, b, c, d)
  if ev == "user" then
    add_block(st, { kind = "user", text = a })
  elseif ev == "assistant_start" then
    finish_live(st)
    local blk = { kind = "assistant", text = "", done = 0, md = {}, started = false }
    st.blocks[#st.blocks + 1] = blk
    st.live = blk
  elseif ev == "text" then
    if st.live then
      st.live.text = st.live.text .. a
      if st.chan and not st.replaying then
        emit(st, assistant_rows(st.live, st.width, false))
      end
    end
  elseif ev == "assistant_end" then
    finish_live(st)
  elseif ev == "tool_start" then
    -- a = call, b = summary, c = category
    st.pending[#st.pending + 1] = { kind = "tool", id = a.id, name = a.name or "tool", summary = shorten(b, 200), category = c }
  elseif ev == "tool_end" then
    -- a = call, b = result, c = is_err, d = denied
    for _, t in ipairs(st.pending) do
      if t.id == a.id then
        t.finished, t.result, t.err, t.denied = true, b, c, d
      end
    end
    commit_pending(st)
  elseif ev == "error" then
    add_block(st, { kind = "error", text = a })
  elseif ev == "notice" then
    add_block(st, { kind = "notice", text = a })
  elseif ev == "status" then
    return M.set_status(st, a)
  elseif ev == "done" then
    finish_live(st)
    for _, t in ipairs(st.pending) do
      t.finished, t.result = true, t.result or "прервано"
    end
    commit_pending(st)
    if a then
      add_block(st, { kind = "stop", text = "прервано" })
    end
  elseif ev == "reset" then
    st.blocks, st.live, st.pending = { { kind = "banner" } }, nil, {}
    M.rebuild(st)
  elseif ev == "need_model" then
    vim.schedule(function()
      require("aqua.ai").select_model(function(ok)
        if ok then st.session:send(a) end
      end)
    end)
  end
  schedule_draw(st)
end

--- Восстановить переписку из сохранённой истории.
local function replay(st)
  st.replaying = true
  for _, m in ipairs(st.session.messages) do
    if m.role == "user" and m.harness then
      M.on_event(st, "notice", "напоминание модели от харнеса")
    elseif m.role == "user" then
      M.on_event(st, "user", m.content)
    elseif m.role == "assistant" then
      M.on_event(st, "assistant_start", config.profile())
      if m.content and m.content ~= "" then
        M.on_event(st, "text", m.content)
      end
      M.on_event(st, "assistant_end", m)
      for _, call in ipairs(m.tool_calls or {}) do
        local tool = require("aqua.ai.tools").get(call.name)
        M.on_event(st, "tool_start", call, require("aqua.ai.tools").summary(call.name, call.args), tool and tool.category or "read")
      end
    elseif m.role == "tool" then
      local denied = m.content:match("^Пользователь отклонил") ~= nil
      M.on_event(st, "tool_end", { id = m.tool_call_id }, m.content, denied, denied)
    end
  end
  -- инструменты без результата (сессию прервали)
  for _, t in ipairs(st.pending) do
    t.finished, t.result = true, t.result or "прервано"
  end
  commit_pending(st)
  st.replaying = false
end

-- ── Ввод ────────────────────────────────────────────────────────────────────

function M.input_text(st)
  return st.ed.text
end

function M.set_input(st, text)
  editor.set(st.ed, text)
  schedule_draw(st)
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Aqua AI" })
end

local function slash(st, text)
  local cmd, rest = text:match("^/(%w+)%s*(.*)$")
  if not cmd then
    return false
  end
  if cmd == "help" then
    add_block(st, { kind = "info", text = require("aqua.ai").help_text() })
    return true
  end
  if cmd == "exit" or cmd == "quit" then
    -- окно закрываем после обработки нажатия (мы внутри обработчика ввода терминала)
    vim.schedule(function() M.hide(st) end)
    return true
  end
  local fn = SLASH[cmd]
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
  local text = vim.trim(st.ed.text)
  if text == "" then
    return
  end
  if slash(st, text) then
    M.set_input(st, "")
    return
  end
  local h = st.ed.history
  if h[#h] ~= text then
    h[#h + 1] = text
  end
  st.ed.hidx, st.ed.draft = nil, nil
  editor.set(st.ed, "")
  -- пока модель отвечает, сообщение встаёт в очередь — поле ввода всегда свободно
  local ok, err = st.session:send(text)
  if not ok then
    editor.set(st.ed, text) -- не теряем набранное
    notify(err, vim.log.levels.WARN)
  end
  schedule_draw(st)
end

--- Esc, как в Claude Code: останавливает ответ модели и очищает очередь.
function M.esc(st)
  if st.session.running then
    local queued = #st.session.queue
    st.session:cancel()
    if queued > 0 then
      notify(("Прервано. Очередь очищена (сообщений: %d)"):format(queued), vim.log.levels.WARN)
    end
  end
end

--- Ctrl-C: останавливает ответ; когда модель молчит — очищает поле ввода.
function M.ctrl_c(st)
  if st.session.running then
    return M.esc(st)
  end
  M.set_input(st, "")
end

local function complete(st)
  local cmd = st.ed.text:match("^/(%w*)$")
  if not cmd then
    return
  end
  for _, c in ipairs(M.commands) do
    if c[1]:sub(1, #cmd) == cmd then
      editor.set(st.ed, "/" .. c[1] .. (c[1] == "model" and " " or ""))
      return
    end
  end
end

--- Байты из терминала (нажатия клавиш, вставка).
---@param st aqua.ai.UI
---@param data string
function M.feed(st, data)
  for _, ev in ipairs(editor.decode(st.dec, data)) do
    local action = editor.apply(st.ed, ev)
    if action == "submit" then
      M.submit(st)
    elseif action == "esc" then
      M.esc(st)
    elseif action == "interrupt" then
      M.ctrl_c(st)
    elseif action == "tab" then
      complete(st)
    elseif action == "redraw" then
      M.rebuild(st)
    elseif action == "scroll_up" or action == "scroll_down" then
      local keys = action == "scroll_up" and "<C-\\><C-n><C-b>" or "<C-\\><C-n><C-f>"
      vim.api.nvim_feedkeys(vim.keycode(keys), "n", false)
    end
  end
  schedule_draw(st)
end

--- Дописать текст в поле ввода (файл, выделение, диагностика) и перейти к вводу.
---@param st aqua.ai.UI
---@param text string
function M.add_to_input(st, text)
  local existing = st.ed.text
  editor.set(st.ed, existing == "" and text or (existing .. (existing:match("%s$") and "" or "\n") .. text))
  M.focus(st)
  schedule_draw(st)
end

-- ── Терминальный буфер и окно ───────────────────────────────────────────────

local function term_width(st)
  local info = vim.fn.getwininfo(st.win)[1]
  return math.max(20, vim.api.nvim_win_get_width(st.win) - (info and info.textoff or 0) - 1)
end

local function window_opts(win)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn = false, false, "no"
  wo.foldcolumn, wo.cursorline, wo.list, wo.spell = "0", false, false, false
  wo.statuscolumn = ""
  wo.winfixwidth = true
  wo.sidescrolloff = 0
  wo.winbar = "%!v:lua.require'aqua.ai.ui'.winbar()"
  wo.winhighlight = "Normal:AquaAINormal,NormalNC:AquaAINormal,WinBar:AquaAIBar,WinBarNC:AquaAIBar"
end

local function setup_buf(st, buf)
  local function map(mode, lhs, rhs, desc, extra)
    vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", { buffer = buf, silent = true, nowait = true, desc = "Aqua AI: " .. desc }, extra or {}))
  end
  local hide = function() M.hide(st) end
  map({ "n", "t" }, "<C-,>", hide, "скрыть чат")
  map("n", "q", hide, "скрыть чат")
  -- переход в другие окна прямо из режима ввода (как в терминале Claude)
  map("t", "<C-h>", "<Cmd>wincmd h<CR>", "окно слева")
  map("t", "<C-k>", "<Cmd>wincmd k<CR>", "окно сверху")
  map("t", "<C-w>", "<C-\\><C-n><C-w>", "команды окон (Ctrl-W h / w / c …)", { nowait = false })
  -- Esc — в чат (стоп ответа), Esc Esc — режим Normal: прокрутка, поиск, копирование
  map("t", "<Esc>", function()
    if st.esc_timer and st.esc_timer:is_active() then
      st.esc_timer:stop()
      return "<C-\\><C-n>"
    end
    st.esc_timer = st.esc_timer or assert(uv.new_timer())
    st.esc_timer:start(250, 0, function() end)
    return "<Esc>"
  end, "Esc — стоп · Esc Esc — режим Normal", { expr = true })
  map("n", "<C-c>", function() M.esc(st) end, "прервать ответ")
  map("n", "gf", function()
    local f = vim.fn.expand("<cfile>"):gsub("^@", ""):gsub("#L%d+.*$", "")
    local abs = vim.fs.normalize(f:sub(1, 1) == "/" and f or (st.root .. "/" .. f))
    if vim.fn.filereadable(abs) == 1 then
      M.open_in_editor(abs, nil, true)
    else
      notify("Файл не найден: " .. f, vim.log.levels.WARN)
    end
  end, "открыть файл в редакторе")
  map("n", "]]", function() vim.fn.search("^\\(❯\\|●\\) ", "W") end, "следующее сообщение")
  map("n", "[[", function() vim.fn.search("^\\(❯\\|●\\) ", "bW") end, "предыдущее сообщение")
  -- вернулись в окно чата (клик, Ctrl-L, после окна подтверждения) — сразу ввод
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode ~= "t" then
          vim.cmd.startinsert()
        end
      end)
    end,
  })
end

--- Новый терминальный буфер в окне чата (старый удаляется).
local function attach_term(st)
  local old = st.buf
  local buf = vim.api.nvim_create_buf(false, true)
  st.buf = buf
  vim.api.nvim_win_set_buf(st.win, buf)
  window_opts(st.win)
  st.chan = vim.api.nvim_open_term(buf, {
    on_input = function(_, _, _, data)
      M.feed(st, data)
    end,
  })
  vim.bo[buf].scrollback = 100000
  vim.bo[buf].filetype = "aqua_ai"
  vim.b[buf].aqua_ai_root = st.root
  vim.b[buf].aqua_agent = { id = "aqua_ai", name = "Aqua AI", icon = ICON, cwd = st.root }
  vim.b[buf].snacks_indent = false
  vim.b[buf].snacks_scroll = false
  vim.b[buf].completion = false
  setup_buf(st, buf)
  if valid_buf(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  pcall(vim.api.nvim_buf_set_name, buf, "aqua-ai://" .. st.root)
end

--- Перерисовать всю переписку заново (смена ширины, /new, Ctrl-L).
---@param st aqua.ai.UI
function M.rebuild(st)
  if not valid_win(st.win) then
    st.stale = true
    return
  end
  st.stale = false
  local was_term = vim.api.nvim_get_current_win() == st.win and vim.api.nvim_get_mode().mode == "t"
  attach_term(st)
  st.width = term_width(st)
  st.height = height(st)
  st.dyn, st.out = 0, {}
  -- bracketed paste + kitty-клавиатура (Shift+Enter, однозначный Esc)
  pcall(vim.api.nvim_chan_send, st.chan, "\27[?2004h\27[>1u")
  local rows = {}
  for _, b in ipairs(st.blocks) do
    if b == st.live then
      b.done, b.md, b.started = 0, {}, false
      vim.list_extend(rows, assistant_rows(b, st.width, false))
    else
      vim.list_extend(rows, block_rows(st, b, st.width))
    end
  end
  st.out = render.to_ansi(rows, st.width)
  draw(st)
  if was_term then
    vim.cmd.startinsert()
  end
end

local function new_state(root)
  ---@type aqua.ai.UI
  local st = {
    root = root,
    session = session_mod.get(root),
    width = 60,
    blocks = { { kind = "banner" } },
    pending = {},
    out = {},
    dyn = 0,
    ed = editor.new(),
    dec = editor.decoder(),
    status = "idle",
    spinner = 1,
    stale = true,
  }
  st.session.cb = function(ev, ...) M.on_event(st, ev, ...) end
  M.states[root] = st
  replay(st)
  return st
end

---@param root string
function M.state(root)
  return M.states[root] or new_state(root)
end

function M.visible_state()
  for _, st in pairs(M.states) do
    if valid_win(st.win) then
      return st
    end
  end
end

function M.focus(st)
  if valid_win(st.win) then
    vim.api.nvim_set_current_win(st.win)
    vim.cmd.startinsert()
  end
end
M.focus_input = M.focus

---@param st aqua.ai.UI
function M.hide(st)
  if valid_win(st.win) then
    if #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0)) <= 1 then
      vim.cmd("vnew") -- последнее окно не закрыть — оставим пустой буфер
    end
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  st.win = nil
end

function M.hide_all()
  for _, st in pairs(M.states) do
    M.hide(st)
  end
end

local function open_window(st)
  local cfg = config.get()
  vim.cmd("botright vsplit")
  st.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(st.win, math.max(40, math.floor(vim.o.columns * cfg.width)))
  if valid_buf(st.buf) and not st.stale then
    vim.api.nvim_win_set_buf(st.win, st.buf)
    window_opts(st.win)
    if st.width == term_width(st) then
      schedule_draw(st)
    else
      M.rebuild(st)
    end
  else
    M.rebuild(st)
  end
  st.size = { vim.api.nvim_win_get_width(st.win), vim.api.nvim_win_get_height(st.win) }
end

--- Открыть чат проекта (или сфокусировать, если уже открыт).
---@param root string
function M.open(root)
  local cur = M.visible_state()
  if cur and cur.root == root then
    M.focus(cur)
    return cur
  end
  if cur then
    M.hide(cur)
  end
  -- агенты в терминале (Claude) занимают то же место справа
  local ok, agent = pcall(require, "aqua.agent")
  if ok then
    for _, a in pairs(agent.agents) do
      a.hide_all()
    end
  end
  local st = M.state(root)
  open_window(st)
  M.focus(st)
  return st
end

--- Показать / скрыть.
---@param root string
function M.toggle(root)
  local cur = M.visible_state()
  if cur and (cur.root == root or vim.api.nvim_get_current_win() == cur.win) then
    M.hide(cur)
    return
  end
  return M.open(root)
end

--- Строки переписки как текст (без цветов) — для тестов и отладки.
---@param st aqua.ai.UI
---@return string[]
function M.lines(st)
  if not valid_buf(st.buf) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    lines[#lines] = nil
  end
  return vim.tbl_map(function(l) return (l:gsub("%s+$", "")) end, lines)
end

function M.text(st)
  return table.concat(M.lines(st), "\n")
end

--- Обычное окно редактора (для файлов, случайно открытых в окне чата).
local function editor_window()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative == "" and not vim.b[b].aqua_ai_root and vim.bo[b].buftype ~= "terminal" then
      local mine = false
      for _, st in pairs(M.states) do
        mine = mine or st.win == w
      end
      if not mine then
        return w
      end
    end
  end
end

local group = vim.api.nvim_create_augroup("aqua_ai_ui", { clear = true })
-- Ширина окна изменилась — текст переносится заново.
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = group,
  callback = function()
    for _, st in pairs(M.states) do
      if valid_win(st.win) then
        local size = { vim.api.nvim_win_get_width(st.win), vim.api.nvim_win_get_height(st.win) }
        if not vim.deep_equal(size, st.size) then
          st.size = size
          if st.resize_timer then st.resize_timer:stop() end
          st.resize_timer = vim.defer_fn(function()
            st.resize_timer = nil
            if valid_win(st.win) then M.rebuild(st) end
          end, 40)
        end
      end
    end
  end,
})
-- Файл открыли прямо в окне чата (:e, пикер, gd…) — переносим его в окно редактора,
-- а чат остаётся на месте (как у терминала Claude).
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = group,
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    for _, st in pairs(M.states) do
      if st.win == win and valid_buf(st.buf) and ev.buf ~= st.buf then
        vim.schedule(function()
          if not (valid_win(st.win) and vim.api.nvim_win_get_buf(st.win) == ev.buf and valid_buf(st.buf)) then
            return
          end
          vim.api.nvim_win_set_buf(st.win, st.buf)
          window_opts(st.win)
          local target = editor_window()
          if target then
            vim.api.nvim_win_set_buf(target, ev.buf)
            vim.api.nvim_set_current_win(target)
          else
            vim.cmd("topleft vsplit")
            vim.api.nvim_win_set_buf(0, ev.buf)
            vim.api.nvim_win_set_width(st.win, math.max(40, math.floor(vim.o.columns * config.get().width)))
          end
        end)
      end
    end
  end,
})
-- Смена темы — новые цвета.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    render.clear_cache()
    for _, st in pairs(M.states) do
      if valid_win(st.win) then M.rebuild(st) end
    end
  end,
})

-- ── Winbar, статус, открытие файлов ─────────────────────────────────────────

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
  local text = ("%%#AquaAIBar#  %s Aqua AI %%#AquaAIInfo# %s · %s "):format(ICON, esc(profile.model or "модель не выбрана"), esc(profile.name))
  local right = ""
  if st.status ~= "idle" then
    right = (SPINNER[st.spinner] or SPINNER[1]) .. " " .. (st.status == "approval" and "ждёт подтверждения" or "работает")
  end
  if st.session.yolo then
    right = "⚡ YOLO  " .. right
  end
  return text .. "%=%#AquaAIStatus#" .. right .. " "
end

--- Открыть файл в обычном окне редактора (не в окне чата).
---@param abs string
---@param line? integer
---@param focus? boolean перейти в это окно (иначе фокус остаётся в чате)
function M.open_in_editor(abs, line, focus)
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
  if focus then
    vim.api.nvim_set_current_win(target)
  end
end

--- Для статусной строки.
function M.statusline()
  if next(M.states) == nil then
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
