-- Режим чтения Markdown: <leader>mr — переключатель «чтение ⇄ редактирование».
--
-- Чтение: текст в центрированной колонке без лишнего интерфейса, разметка скрыта (в том числе на
-- строке курсора), никаких диагностик (линтер, LSP) и красной орфографии, буфер защищён от случайных правок.
--   q / Esc / <leader>mr — выйти        i a o I A O e — выйти и сразу редактировать
--   ]] / [[ — следующий / предыдущий заголовок        <leader>mo — оглавление
-- Настройка: vim.g.aqua_reader = { width = 100 }
local M = {}

---@class aqua.reader.State
---@field buf integer
---@field win snacks.win
---@field undo fun()[]
---@field keys { mode: string, lhs: string }[]

---@type aqua.reader.State?
M.active = nil

local function cfg()
  local user = type(vim.g.aqua_reader) == "table" and vim.g.aqua_reader or {}
  return vim.tbl_deep_extend("force", { width = 100 }, user)
end

--- Режим чтения активен (окно существует).
function M.is_active()
  return M.active ~= nil and M.active.win:valid()
end

local function is_markdown(buf)
  return vim.bo[buf].filetype:match("^markdown") ~= nil
end

-- ── Заголовки ───────────────────────────────────────────────────────────────

--- Заголовки документа для оглавления и навигации.
---@param buf integer
---@return { line: integer, level: integer, title: string }[]
function M.headings(buf)
  return require("aqua.ai.tools.md").headings(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

--- Перейти к следующему / предыдущему заголовку.
---@param dir 1|-1
function M.jump_heading(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _, h in ipairs(M.headings(buf)) do
    if dir > 0 and h.line > cur then
      target = h.line
      break
    elseif dir < 0 and h.line < cur then
      target = h.line
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! zt")
  end
end

--- Оглавление (Snacks picker): выбор заголовка переносит курсор к нему.
function M.outline()
  local buf = vim.api.nvim_get_current_buf()
  if not is_markdown(buf) then
    return vim.notify("Оглавление доступно только для Markdown", vim.log.levels.INFO, { title = "AquaNvim" })
  end
  local win = vim.api.nvim_get_current_win()
  local items = {}
  for _, h in ipairs(M.headings(buf)) do
    items[#items + 1] = {
      text = h.title,
      title = h.title,
      level = h.level,
      pos = { h.line, 0 },
      file = vim.api.nvim_buf_get_name(buf),
      buf = buf,
    }
  end
  Snacks.picker({
    title = "󰉫 Оглавление",
    items = items,
    format = function(item)
      return { { ("  "):rep(item.level - 1) .. ("#"):rep(item.level) .. " ", "Comment" }, { item.title, item.level == 1 and "Title" or "Normal" } }
    end,
    preview = "none",
    layout = { preset = "select" },
    confirm = function(picker, item)
      picker:close()
      if item and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { item.pos[1], 0 })
        vim.cmd("normal! zt")
      end
    end,
  })
end

-- ── Вход / выход ────────────────────────────────────────────────────────────

local function run_undo(st)
  for _, fn in ipairs(st.undo) do
    pcall(fn)
  end
  st.undo = {}
  for _, k in ipairs(st.keys) do
    pcall(vim.keymap.del, k.mode, k.lhs, { buffer = st.buf })
  end
  st.keys = {}
end

--- Принудительно перерисовать render-markdown для буфера (если плагин есть).
local function rerender(buf)
  pcall(function()
    require("render-markdown.api").render({ buf = buf, event = "AquaReader" })
  end)
end

---@param buf? integer
function M.enter(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if M.is_active() then
    return
  end
  if not is_markdown(buf) then
    return vim.notify("Режим чтения доступен только для Markdown-файлов", vim.log.levels.INFO, { title = "AquaNvim" })
  end
  -- Если открыт обычный «zen» Snacks — закрываем, иначе Snacks.zen() его выключит вместо открытия
  if Snacks.zen.win and Snacks.zen.win:valid() then
    Snacks.zen.win:close()
  end

  ---@type aqua.reader.State
  local st = { buf = buf, undo = {}, keys = {} }
  local function undo(fn)
    table.insert(st.undo, 1, fn)
  end

  -- 1) Никаких ошибок: диагностика буфера (линтер, LSP) выключается
  local diag_was = vim.diagnostic.is_enabled({ bufnr = buf })
  vim.diagnostic.enable(false, { bufnr = buf })
  undo(function()
    if vim.api.nvim_buf_is_valid(buf) then vim.diagnostic.enable(diag_was, { bufnr = buf }) end
  end)

  -- 2) Только чтение
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false
  undo(function()
    if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = modifiable end
  end)

  -- 3) Разметка скрыта и на строке курсора (render-markdown без anti-conceal)
  pcall(function()
    local conf = require("render-markdown.state").get(buf)
    local was = conf.anti_conceal.enabled
    conf.anti_conceal.enabled = false
    undo(function()
      conf.anti_conceal.enabled = was
      rerender(buf)
    end)
  end)

  -- 4) Окно: центрированная колонка, перенос по словам, без номеров / знаков / орфографии
  local width = cfg().width
  local win = Snacks.zen({
    toggles = { dim = false, git_signs = false, mini_diff_signs = false },
    win = {
      width = width,
      -- Непрозрачная подложка: исходное окно (и его диагностики) сквозь затемнение не просвечивают
      backdrop = {
        transparent = false,
        blend = 0,
        win = { wo = { winhighlight = "Normal:AquaReaderNormal", winblend = 0 } },
      },
      wo = {
        wrap = true, linebreak = true, breakindent = true, breakindentopt = "list:-1",
        number = false, relativenumber = false, signcolumn = "no", foldcolumn = "0",
        cursorline = false, list = false, spell = false, colorcolumn = "",
        conceallevel = 3, concealcursor = "nvic", statuscolumn = "",
        scrolloff = 6, sidescrolloff = 0,
        winbar = "%#AquaReaderBar#  󰂺 Режим чтения %#AquaReaderHint#  i — редактировать · q — выйти · ]] [[ — разделы · Space m o — оглавление",
        winhighlight = "Normal:AquaReaderNormal,NormalFloat:AquaReaderNormal,WinBar:AquaReaderBar,WinBarNC:AquaReaderBar",
      },
    },
    on_close = function()
      if M.active == st then
        M.active = nil
      end
      run_undo(st)
    end,
  })
  st.win = win
  M.active = st

  -- 5) Подсветка и индентация-гайды не нужны для чтения
  local saved_indent = vim.b[buf].snacks_indent
  vim.b[buf].snacks_indent = false
  undo(function()
    if vim.api.nvim_buf_is_valid(buf) then vim.b[buf].snacks_indent = saved_indent end
  end)

  -- 6) Клавиши (только в буфере и только пока идёт чтение)
  local function map(mode, lhs, fn, desc)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = "Reader: " .. desc })
    st.keys[#st.keys + 1] = { mode = mode, lhs = lhs }
  end
  -- (<leader>mr и <leader>mo назначены в markdown-буферах всегда — см. config/autocmds.lua)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map("n", lhs, function() M.exit() end, "выйти из режима чтения")
  end
  -- i a o I A O e: выйти и продолжить как в обычном редактировании
  for _, key in ipairs({ "i", "a", "o", "I", "A", "O" }) do
    map("n", key, function() M.exit(key) end, "редактировать (" .. key .. ")")
  end
  map("n", "e", function() M.exit() end, "редактировать")
  map("n", "]]", function() M.jump_heading(1) end, "следующий заголовок")
  map("n", "[[", function() M.jump_heading(-1) end, "предыдущий заголовок")

  rerender(buf)
  return st
end

--- Выйти из режима чтения. `then_key` — клавиша редактирования, которую нужно выполнить после выхода.
---@param then_key? string
function M.exit(then_key)
  local st = M.active
  if not st then
    return
  end
  if st.win:valid() then
    st.win:close() -- on_close вернёт все настройки
  else
    M.active = nil
    run_undo(st)
  end
  if then_key then
    vim.schedule(function()
      vim.api.nvim_feedkeys(vim.keycode(then_key), "n", false)
    end)
  end
end

---@param buf? integer
function M.toggle(buf)
  if M.is_active() then
    return M.exit()
  end
  return M.enter(buf)
end

return M
